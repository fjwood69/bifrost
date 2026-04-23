# Claude Code Compatibility — Fork Notes

This document describes the `claude-code-compat` branch of this Bifrost fork: why it exists, what was built, what broke, and how each issue was fixed.

---

## Goal

[Claude Code](https://claude.ai/code) is Anthropic's official agentic CLI. Its SDK enforces Anthropic-specific conventions throughout — model names, API schema, content block types, token counting, and more. Out of the box it only speaks to `api.anthropic.com`.

The goal here was to point Claude Code at a local Bifrost gateway instead, so that requests transparently route to other inference providers (Parasail, Google Gemini, Vertex AI MaaS) without the client knowing or caring. This gives Claude Code's polished agentic UX — Plan Mode, subagents, tool orchestration — on top of open or third-party models, with full billing control.

---

## Setup

**Environment**: Ubuntu host, Bifrost running as a local service or container.

**The core trick** is making Claude Code believe it is talking to Anthropic while actually talking to Bifrost:

```bash
ANTHROPIC_BASE_URL=http://localhost:8787/anthropic
ANTHROPIC_API_KEY=sk-ant-api03-claudejr00bifrostgateway0000   # fake sk-ant- prefix
```

Claude Code's SDK validates that `ANTHROPIC_API_KEY` begins with `sk-ant-`. Bifrost's native virtual keys use `sk-bf-`, which the SDK rejects client-side before any request is sent. The workaround: register a virtual key in Bifrost whose *value* is a valid-looking `sk-ant-` string, then use that same string as the environment variable. Bifrost matches the incoming key to the virtual key record and routes to the configured provider; the fake key never reaches Anthropic.

Provider routing is by model ID prefix in the request body:
- `parasail/...` → Parasail (OpenAI-compatible, `api.parasail.io`)
- `gemini/...` → Google Gemini API
- `vertex/...` → Vertex AI MaaS

A `jr-model` shell script switches the active model and keeps `ANTHROPIC_CUSTOM_MODEL_OPTION` in sync (required because Claude Code's internal model validator rejects non-`claude-*` IDs).

---

## Issues Encountered and Fixed

Running Claude Code through Bifrost surfaced a series of compatibility problems. Each is described below in the order it was hit.

### 1. `count_tokens` Preflight — Session Startup Failure

**Symptom**: Every Claude Code session failed to start with a 500 error before any prompt was processed.

**Cause**: The Anthropic SDK sends `POST /v1/messages/count_tokens` before every session as a preflight check. Parasail and other OpenAI-compatible providers do not implement this endpoint. Bifrost had no handler for it.

**Fix**: Added a `ShortCircuit` on the `count_tokens` route in the Anthropic integration handler (`integrations/anthropic.go`). For non-Anthropic providers it immediately returns a zero-count stub that satisfies the SDK:

```json
{"input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
```

Note: `output_tokens` and `total_tokens` are intentionally absent — they do not exist in the real Anthropic `count_tokens` response, and the SDK panics with a nil-pointer dereference if they are present.

---

### 2. Thinking Blocks in Non-Anthropic Responses — 400 Errors

**Symptom**: Responses from Qwen3.5, Gemma, and other models with reasoning/thinking enabled caused Claude Code to crash with a 400 error.

**Cause**: These providers return reasoning content (thinking blocks) in their responses. The Anthropic SDK expects thinking blocks to carry a cryptographic `signature` field issued by Anthropic's infrastructure. Non-Anthropic thinking blocks have no such signature. The SDK rejects the response: *"Content block is not a thinking block"*.

Additionally, some providers return a `redacted_thinking` block type which is not valid in a non-Anthropic context.

**Fix** (across both streaming and non-streaming paths in `providers/anthropic/responses.go`):
- Filter `redacted_thinking` content blocks before they reach the SDK
- Skip `reasoning` / `thinking` `content_block_start` SSE events for non-Anthropic providers
- Track the `output_index` of any suppressed block and suppress the corresponding `content_block_delta` and `content_block_stop` events that follow it

---

### 3. DeepSeek DSML Markers Leaking into Text Output

**Symptom**: DeepSeek V3.2 responses contained raw `<｜DSML｜`, `<｜function_call>` and `</｜function_call>` delimiter strings in the visible text output.

**Cause**: DeepSeek uses a proprietary DSML (DeepSeek Markup Language) format to delimit reasoning sections and tool calls in raw model output. The Parasail and Vertex AI MaaS providers surface this raw format through the OpenAI-compatible streaming layer. Bifrost was passing it through unmodified.

**Fix** (iterative — took several passes to get right):

1. Initial approach: regex-based stripping in `responses.go` — worked for complete markers but missed markers split across SSE chunk boundaries.
2. Added a rolling 20-byte suffix buffer (`stripDSMLFromStreamDeltaWithBuffer`) to catch markers split between two consecutive SSE events.
3. Final approach: centralized stateful suppression in `StripDeepSeekMarkersWithState` (in `schemas/utils.go`). Once any DSML marker is detected, a `dsmlTextSuppressed` flag is set permanently for the lifetime of the stream. All subsequent `Delta.Content` is zeroed. This cleanly handles arbitrarily split markers and prevents any DSML content from reaching the client.

The centralized function is called from `HandleOpenAIChatCompletionStreaming` in `providers/openai/openai.go` and applies to all OpenAI-compatible provider paths.

---

### 4. Tool Call Arguments Dropped for DeepSeek and Qwen

**Symptom**: After the DSML suppression was in place, tool calls from DeepSeek and Qwen3.5 arrived with empty inputs — `file_path` missing, `content` missing, etc. Models appeared to reason about what to do but never passed arguments through.

**Cause**: The `dsmlTextSuppressed` kill-switch (fix 3) zeroes *all* `Delta.Content` after the first DSML marker. This is correct for text output, but DeepSeek in thinking mode also emits `<｜function_call>` in the content stream *before* switching to proper tool-call deltas. Once suppression fires, tool argument chunks that arrive in subsequent `Delta.Content` events are also zeroed.

**Fix**: Rather than trying to distinguish "tool argument content" from "DSML content" in the suppression layer (which is fragile), disable thinking at source for the affected models. Added `injectThinkingDisable()` in `providers/parasail/parasail.go`, called from both `ChatCompletion` and `ChatCompletionStream` before the OpenAI handler:

- DeepSeek models: injects `chat_template_kwargs: {"thinking": false}` into `ExtraParams`
- Qwen models: injects `chat_template_kwargs: {"enable_thinking": false}` into `ExtraParams`

Sets `BifrostContextKeyPassthroughExtraParams = true` so the extra params are merged into the outbound JSON to Parasail. With thinking disabled at source, no DSML markers appear, the suppressor never fires, and tool arguments flow through intact.

**Verified**: streaming `write_file` tool call with Qwen3.5-35B-A3B-FP8 — `file_path` and `content` both present across all partial-JSON chunks.

---

### 5. Streaming Crash — Nil Pointer on Usage Block

**Symptom**: Intermittent nil-pointer panic in the Anthropic stream converter when a model returned a `message_delta` event without a usage block.

**Fix**: Added nil-guard in `responses.go` before dereferencing the usage pointer from `ConvertBifrostUsageToAnthropicUsage`. Ensured `message_delta` always carries a usage block in the outbound SSE event, even if upstream did not provide one.

---

### 6. `response.incomplete` Not Handled in Stream Converter

**Symptom**: Streams with `finish_reason=length` or `finish_reason=content_filter` (i.e. truncated responses) fell through to a `return nil` default in the stream event converter, silently dropping the stop event.

**Fix**: Added explicit handling for `response.incomplete` in `ToAnthropicResponsesStreamResponse`, mapping it to the appropriate `message_delta` stop event with `stop_reason=max_tokens`.

---

## Current State

All Claude Code agentic features tested and working through Bifrost:

| Feature | Status |
|---|---|
| Basic chat (streaming) | ✅ |
| Tool use (Bash, Read, Write, Edit) | ✅ Qwen3.5, Gemma 26B |
| Plan Mode | ✅ |
| Multi-step agentic tasks | ✅ |
| `count_tokens` preflight | ✅ stub |
| Thinking/reasoning suppression | ✅ |
| DSML marker stripping | ✅ |

**Providers tested**:
- Parasail: Qwen3.5-35B-A3B-FP8, DeepSeek-V3.2, Gemma 4 26B
- Google: Gemini 3 Flash Preview
- Vertex AI MaaS: DeepSeek-V3.2, Gemma 4 26B, GLM-5

**Known limitations**:
- Kimi K2.6 (Parasail): unstable on the standard Chat Completions path — Kimi is designed for a separate Responses API gateway (`api-webflux.saas.parasail.io`). Routing not yet implemented.
- Subagent calls (e.g. `Agent(subagent_type="Explore")`) spawn Haiku 4.5 internally and inherit `ANTHROPIC_BASE_URL`. Bifrost's `ParseModelString` defaults unprefixed `claude-*` model IDs to the Anthropic provider, which would silently bill Anthropic. Mitigation: disable the Anthropic provider key in Bifrost when using this branch for non-Anthropic routing only.

---

## Build

```bash
cd ~/bifrost
docker build -t bifrost:claude-code-compat -f transports/Dockerfile.local .
docker rm -f bifrost
docker run -d --restart=always --network=host --name=bifrost \
  -e APP_PORT=8787 -e APP_HOST=0.0.0.0 \
  -e PARASAIL_API_KEY="..." \
  -e GOOGLE_GEMINI_API_KEY="..." \
  -v /path/to/bifrost/data:/app/data \
  bifrost:claude-code-compat
```

Use `transports/Dockerfile.local` — it builds from the local source tree. Do not use `docker.io/maximhq/bifrost:latest`; it does not contain these fixes.
