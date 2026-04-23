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
- `Deepinfra/...` → DeepInfra (OpenAI-compatible, `api.deepinfra.com/v1/openai`)
- `nebius/...` → Nebius AI Studio (OpenAI-compatible, `api.studio.nebius.com/v1`)

A `jr-model` shell script switches the active model and keeps `ANTHROPIC_CUSTOM_MODEL_OPTION` in sync (required because Claude Code's internal model validator rejects non-`claude-*` IDs).

---

## Workflow

### Profile Isolation

Claude Code stores its config, credentials, and active session in a single directory — `~/.claude/` by default, or wherever `CLAUDE_CONFIG_DIR` points. If you already have Claude Code set up against the Anthropic API or a claude.ai subscription, you don't want Bifrost routing to interfere with it.

The simplest isolation is a shell alias that sets both env vars together:

```bash
alias claude-jr='ANTHROPIC_BASE_URL=http://localhost:8787/anthropic \
  ANTHROPIC_API_KEY=sk-ant-api03-claudejr00bifrostgateway0000 \
  CLAUDE_CONFIG_DIR=$HOME/.claude-jr \
  claude'
```

A separate `CLAUDE_CONFIG_DIR` means Claude Code writes its state, logs, and cached config to a different directory — your main Anthropic session is untouched.

For switching between multiple profiles (e.g. Anthropic API, subscription, and Bifrost), a file-swap approach works well: store a snapshot of `settings.json`, `credentials.json`, and `claude.json` per profile in a `~/.claude-profiles/` directory, and copy the active one into `~/.claude/` on each switch. This keeps the switcher logic simple and Claude Code never knows the difference.

See [`fjwood69/ai-stack`](https://github.com/fjwood69/ai-stack) (`CLAUDE.md` → Claude Code Backend Switcher) for a full implementation of this approach with three profiles (Anthropic API, OAuth subscription, Bifrost/claude-jr) and VS Code sidebar integration.

---

### Model Switching (`ANTHROPIC_CUSTOM_MODEL_OPTION`)

Claude Code validates that model IDs begin with `claude-` before sending the request. Non-`claude-*` model IDs are rejected client-side — the request never reaches Bifrost.

The `ANTHROPIC_CUSTOM_MODEL_OPTION` environment variable bypasses this check. When set, Claude Code substitutes its value as the model ID in every outbound request:

```bash
export ANTHROPIC_CUSTOM_MODEL_OPTION=parasail/Qwen/Qwen3.5-35B-A3B-FP8
```

This is how provider routing works in practice. The env var is set per-session and lives in the profile's `settings.json` under the `env` block:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8787/anthropic",
    "ANTHROPIC_API_KEY": "sk-ant-api03-claudejr00bifrostgateway0000",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "parasail/Qwen/Qwen3.5-35B-A3B-FP8"
  }
}
```

A model switcher script (`jr-model` in the ai-stack reference implementation) updates this field in both the profile store and the live `~/.claude/settings.json`, then optionally reloads Claude Code. It also sets cosmetic display vars `ANTHROPIC_CUSTOM_MODEL_OPTION_NAME` and `ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION` which appear in the Claude Code UI but have no effect on routing.

The plan/act compound model string is set the same way — it's just a value for `ANTHROPIC_CUSTOM_MODEL_OPTION`:

```
plan:Deepinfra/moonshotai/Kimi-K2.6||act:nebius/deepseek-ai/DeepSeek-V3.2
```

---

### Plan/Act — Which Claude Code Mode to Use

The plan/act routing is driven by the presence of `tool_result` blocks in the message history. This has a practical consequence for how you run Claude Code:

**Use "Ask before edits" (normal agentic mode)** — this is the recommended mode for plan/act routing:
- First request: no tool results yet → plan model (e.g. Kimi K2.6) reasons about the problem
- After the first tool call and its result: act model (e.g. DeepSeek V3.2) takes over the mechanical execution loop
- The "ask before edits" pause still fires before file writes, so you retain oversight without losing the model switching benefit

**Avoid explicit Plan Mode** if you want the act model to be invoked. In Plan Mode, Claude Code never emits tool calls — so `tool_result` blocks never appear, every request goes to the plan model, and the act routing never fires. Plan Mode is useful if you want the plan model to write out a full plan for your review before any execution begins, but that means only one model is ever used for that session.

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

### 7. OpenAI-Compat Providers Without `/v1/responses` — 404 Errors

**Symptom**: Custom OpenAI-compatible providers (e.g. DeepInfra) returned 404 errors for every chat request routed through the Anthropic compat layer.

**Cause**: The Anthropic-to-OpenAI translation layer routes all requests through `ResponsesRequest`, which calls `Responses()` / `ResponsesStream()` on the upstream provider. These methods send `POST /v1/responses` — a responses-API endpoint that most third-party OpenAI-compatible providers don't implement (DeepInfra only exposes standard Chat Completions at `/v1/chat/completions`). Providers like Parasail work because they have native `Responses()` overrides that internally convert to a Chat Completion call; the base OpenAI provider does not.

A secondary issue: some providers expose their API at a path that already includes `/v1` (e.g. DeepInfra's base URL is `https://api.deepinfra.com/v1/openai`). Bifrost appends its own `/v1/models`, `/v1/chat/completions` etc., producing doubled paths like `https://api.deepinfra.com/v1/openai/v1/models`. This is fixed independently via `request_path_overrides` in the provider's custom config — set `list_models` → `/models`, `chat_completion` → `/chat/completions`, etc.

**Fix**: Added `UseChatCompletionForResponses bool` to `CustomProviderConfig` in `core/schemas/provider.go`. When set to `true`, the base OpenAI provider's `Responses()` and `ResponsesStream()` methods convert the request via `ToChatRequest()` and call `ChatCompletion()` / `ChatCompletionStream()` instead of attempting a `/v1/responses` call:

```go
// In providers/openai/openai.go
if provider.customProviderConfig != nil && provider.customProviderConfig.UseChatCompletionForResponses {
    chatResponse, bifrostErr := provider.ChatCompletion(ctx, key, request.ToChatRequest())
    // ...
    return chatResponse.ToBifrostResponsesResponse(), nil
}
```

The flag is set per-provider in the custom provider config JSON stored in the Bifrost database. No code changes are needed per provider — any custom OpenAI-compat backend can opt in.

---

### 8. Plan/Act Model Routing for Agentic Tasks

**Motivation**: In a typical Claude Code agentic loop, the model alternates between two distinct cognitive modes — reasoning about what to do (planning) and executing tool calls (acting). These modes have different cost/quality tradeoffs: a strong reasoning model is valuable for planning; a fast, capable coder is better for mechanical execution. Normally Claude Code sends every request to the same model.

**Feature**: Support a compound model string in the format `plan:MODEL_A||act:MODEL_B`. When Bifrost receives a request with this model ID, it inspects the message history to determine which phase the current request represents:

- **Plan phase** — no `tool_result` blocks in any user message → route to `MODEL_A`
- **Act phase** — at least one `tool_result` block present in a user message → route to `MODEL_B`

This signal is reliable because `tool_result` blocks only appear after the model has previously returned a `tool_use` block. The first turn of any task and every intermediate planning turn have no tool results. Tool execution turns always do.

**Implementation** (`transports/bifrost-http/integrations/anthropic.go`):

```go
func parsePlanActModel(model string) (string, string, bool) {
    if !strings.Contains(model, "||") {
        return "", "", false
    }
    var planModel, actModel string
    for _, part := range strings.Split(model, "||") {
        kv := strings.SplitN(strings.TrimSpace(part), ":", 2)
        if len(kv) != 2 { return "", "", false }
        switch strings.TrimSpace(kv[0]) {
        case "plan": planModel = strings.TrimSpace(kv[1])
        case "act":  actModel  = strings.TrimSpace(kv[1])
        }
    }
    if planModel == "" || actModel == "" { return "", "", false }
    return planModel, actModel, true
}

func hasToolResultBlocks(messages []anthropic.AnthropicMessage) bool {
    for _, msg := range messages {
        if msg.Role != "user" { continue }
        for _, block := range msg.Content.ContentBlocks {
            switch block.Type {
            case anthropic.AnthropicContentBlockTypeToolResult,
                 anthropic.AnthropicContentBlockTypeMCPToolResult:
                return true
            }
        }
    }
    return false
}
```

The `RequestConverter` in `createAnthropicMessagesRouteConfig` calls `parsePlanActModel` on every incoming request. If parsing succeeds, `hasToolResultBlocks` selects the target model before `ToBifrostResponsesRequest` is called. Non-compound model strings pass through unchanged.

**Example** (set via `ANTHROPIC_CUSTOM_MODEL_OPTION`):
```
plan:Deepinfra/moonshotai/Kimi-K2.6||act:nebius/deepseek-ai/DeepSeek-V3.2
```

Plan turns route to Kimi K2.6 (strong reasoning, DeepInfra); act turns route to DeepSeek V3.2 (fast coder, Nebius). The full conversation history is forwarded on every request, so the act model always has the plan model's reasoning in context.

**Claude Code mode matters**: For the act model to be invoked, use normal "Ask before edits" mode — tool results accumulate as the agentic loop runs and trigger the switch to the act model. In explicit Plan Mode, Claude Code never emits tool calls, so `tool_result` blocks never appear and every request goes to the plan model. Plan Mode works correctly for that use case (pure planning, single model), but the act routing never fires.

**Verified**: non-streaming and streaming paths tested with explicit plan-phase and act-phase payloads. Response `model` field in both cases correctly reflects the selected downstream model.

---

## Current State

All Claude Code agentic features tested and working through Bifrost:

| Feature | Status |
|---|---|
| Basic chat (streaming) | ✅ |
| Tool use (Bash, Read, Write, Edit) | ✅ Qwen3.5, DeepSeek, Kimi |
| Plan Mode | ✅ |
| Multi-step agentic tasks | ✅ |
| `count_tokens` preflight | ✅ stub |
| Thinking/reasoning suppression | ✅ |
| DSML marker stripping | ✅ |
| Custom provider Chat Completion fallback | ✅ `UseChatCompletionForResponses` flag |
| Plan/Act model routing | ✅ compound model string |

**Providers tested**:
- Parasail: Qwen3.5-35B-A3B-FP8, DeepSeek-V3.2, Gemma 4 26B, Kimi K2.6
- Google: Gemini 3 Flash Preview
- Vertex AI MaaS: DeepSeek-V3.2, Gemma 4 26B, GLM-5
- DeepInfra: DeepSeek-V3.2, Kimi K2.6 (via `UseChatCompletionForResponses`)
- Nebius AI Studio: DeepSeek-V3.2, Qwen3-Next-80B, MiniMax M2.5

**Known limitations**:
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
