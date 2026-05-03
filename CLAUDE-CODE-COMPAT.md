# Claude Code Compatibility — Fork Notes

This document describes the `claude-code-compat` branch of this Bifrost fork: why it exists, what was built, what broke, and how each issue was fixed.

---

## Goal

[Claude Code](https://claude.ai/code) is Anthropic's official agentic CLI. Its SDK enforces Anthropic-specific conventions throughout — model names, API schema, content block types, token counting, and more. Out of the box it only speaks to `api.anthropic.com`.

The goal here was to point Claude Code at a local Bifrost gateway instead, so that requests transparently route to other inference providers (open models, Google Gemini, Vertex AI MaaS) without the client knowing or caring. This gives Claude Code's polished agentic UX — Plan Mode, subagents, tool orchestration — on top of open or third-party models, with full billing control.

---

## Setup

**Environment**: Linux host, Bifrost running as a local service or container.

**The core trick** is making Claude Code believe it is talking to Anthropic while actually talking to Bifrost:

```bash
ANTHROPIC_BASE_URL=http://localhost:8787/anthropic
ANTHROPIC_API_KEY=sk-ant-api03-fakekey00bifrostgateway0000   # fake sk-ant- prefix
```

Claude Code's SDK validates that `ANTHROPIC_API_KEY` begins with `sk-ant-`. Bifrost's native virtual keys use `sk-bf-`, which the SDK rejects client-side before any request is sent. The workaround: register a virtual key in Bifrost whose *value* is a valid-looking `sk-ant-` string, then use that same string as the environment variable. Bifrost matches the incoming key to the virtual key record and routes to the configured provider; the fake key never reaches Anthropic.

Provider routing is by model ID prefix in the request body. Each provider has a unique prefix — Bifrost matches the prefix and routes to the correct backend:

| Provider | Prefix | Example model IDs | Notes |
|----------|--------|-------------------|-------|
| Parasail | `parasail/` | `parasail/google/gemma-4-26B-A4B-it`, `parasail/moonshotai/Kimi-K2.6` | Privacy-safe inference; Qwen3.5, DeepSeek, Gemma, Kimi |
| Google Gemini | `gemini/` | `gemini/gemini-3-flash-preview` | 1M context window; Google Search grounding |
| Vertex AI MaaS | `vertex/` | `vertex/zai-org/glm-5-maas`, `vertex/google/gemma-4-26b-a4b-it-maas` | Google Cloud-hosted managed inference |
| DeepInfra | `Deepinfra/` | `Deepinfra/deepseek-ai/DeepSeek-V4-Flash`, `Deepinfra/moonshotai/Kimi-K2.6` | Fast OpenAI-compatible; **case-sensitive** prefix |
| Nebius AI Studio | `nebius/` | `nebius/deepseek-ai/DeepSeek-V3.2`, `nebius/MiniMaxAI/MiniMax-M2.5` | Good selection of open models |
| Novita | `Novita/` | `Novita/deepseek/deepseek-v4-flash`, `Novita/moonshotai/kimi-k2.6` | Non-standard model IDs (provider's own namespace); **case-sensitive** prefix |
| Moonshot | `Moonshot/` | `Moonshot/kimi-k2.6` | Direct Moonshot API for Kimi models; bare model IDs |

**Prefix case-sensitivity**: `Novita/`, `Deepinfra/`, and `Moonshot/` must match exactly — lowercase variants (`novita/`) will not route.

**Model ID gotchas**: Each provider uses its own naming conventions:
- Parasail and Vertex use Google-style namespaced IDs (`google/gemma-4-26B-A4B-it`)
- DeepInfra uses HuggingFace-style path IDs (`deepseek-ai/DeepSeek-V4-Flash`)
- Novita uses its own internal namespace (`deepseek/deepseek-v4-flash`)
- Moonshot exposes bare model IDs without namespaces (`kimi-k2.6`)

**Notable performers**: DeepSeek V4 Flash has proven very capable as an everyday model through Bifrost — fast, 1M context window, competitive quality, and available across multiple providers (DeepInfra, Novita, Parasail) so routing rules distribute load and provide fallback coverage.

A model-switching script updates the active model and keeps `ANTHROPIC_CUSTOM_MODEL_OPTION` in sync (required because Claude Code's internal model validator rejects non-`claude-*` IDs).

---

## Workflow

### Profile Isolation

Claude Code stores its config, credentials, and active session in a single directory — `~/.claude/` by default, or wherever `CLAUDE_CONFIG_DIR` points. If you already have Claude Code set up against the Anthropic API or a claude.ai subscription, you don't want Bifrost routing to interfere with it.

The simplest isolation is a shell alias that sets both env vars together:

```bash
alias claude-jr='ANTHROPIC_BASE_URL=http://localhost:8787/anthropic \
  ANTHROPIC_API_KEY=sk-ant-api03-fakekey00bifrostgateway0000 \
  CLAUDE_CONFIG_DIR=$HOME/.claude-jr \
  claude'
```

A separate `CLAUDE_CONFIG_DIR` means Claude Code writes its state, logs, and cached config to a different directory — your main Anthropic session is untouched.

For switching between multiple profiles (e.g. Anthropic API, subscription, and Bifrost), a file-swap approach works well: store a snapshot of `settings.json`, `credentials.json`, and `claude.json` per profile in a `~/.claude-profiles/` directory, and copy the active one into `~/.claude/` on each switch. This keeps the switcher logic simple and Claude Code never knows the difference.

### VS Code Extension — The Two-Key Hack

The CLI is only half the story. When running Claude Code inside VS Code (the extension), there are **two separate auth paths**:

1. **CLI subprocess** — reads `ANTHROPIC_API_KEY` from the `env` block in `settings.json`
2. **Extension host AuthManager** — reads `primaryApiKey` from `.claude.json`

A single API key in one file won't satisfy both. The CLI sends its key; the extension host sends a different key from `.claude.json`. If the extension host doesn't find a valid-looking key, it redirects to the `/login` page and never initialises the chat panel.

The fix is two virtual keys in Bifrost:

| Key location | Used by | Bifrost VK matched |
|---|---|---|
| `settings.json` → `env.ANTHROPIC_API_KEY` | CLI subprocess | `claude-jr` (fake key) |
| `.claude.json` → `primaryApiKey` | Extension AuthManager | `claude-jr-passthrough` (real Anthropic API key) |

Both VKs have identical `description` fields (containing the `model_override` JSON), so routing is consistent regardless of which key carries the request. Neither key reaches Anthropic — both are intercepted locally by Bifrost VKs.

**Critical**: The `ANTHROPIC_AUTH_TOKEN` field must be **absent** from `settings.json`. If set to an empty string `""`, the Anthropic SDK emits `Authorization: Bearer ` (blank value) which takes precedence over `x-api-key` in Bifrost's VK parser. The VK is never matched, `model_override` never fires, and Plan/Act routing silently breaks.

### Model Switching (`ANTHROPIC_CUSTOM_MODEL_OPTION`)

Claude Code validates that model IDs begin with `claude-` before sending the request. Non-`claude-*` model IDs are rejected client-side — the request never reaches Bifrost.

The `ANTHROPIC_CUSTOM_MODEL_OPTION` environment variable bypasses this check. When set, Claude Code substitutes its value as the model ID in every outbound request:

```bash
export ANTHROPIC_CUSTOM_MODEL_OPTION=parasail/google/gemma-4-26B-A4B-it
```

This is how provider routing works in practice. The env var is set per-session and lives in the profile's `settings.json` under the `env` block:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8787/anthropic",
    "ANTHROPIC_API_KEY": "sk-ant-api03-fakekey00bifrostgateway0000",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "parasail/google/gemma-4-26B-A4B-it"
  }
}
```

A model switcher script updates this field in both the profile store and the live `~/.claude/settings.json`, then optionally reloads Claude Code. It also sets cosmetic display vars `ANTHROPIC_CUSTOM_MODEL_OPTION_NAME` and `ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION` which appear in the Claude Code UI but have no effect on routing.

The plan/act compound model string is set the same way — though as noted in the Plan/Act section below, routing for Plan/Act actually relies on the VK `model_override` rather than this env var:

```
plan:Deepinfra/moonshotai/Kimi-K2.6||act:nebius/deepseek-ai/DeepSeek-V3.2
```

### Plan/Act — Which Claude Code Mode to Use

The plan/act routing is driven by the presence of `tool_result` blocks in the message history. This has a practical consequence for how you run Claude Code:

**Use "Ask before edits" (normal agentic mode)** — this is the recommended mode for plan/act routing:
- First request: no tool results yet → plan model (e.g. Kimi K2.6) reasons about the problem
- After the first tool call and its result: act model (e.g. DeepSeek V3.2) takes over the mechanical execution loop
- The "ask before edits" pause still fires before file writes, so you retain oversight without losing the model switching benefit

**Avoid explicit Plan Mode** if you want the act model to be invoked. In Plan Mode, Claude Code never emits tool calls — so `tool_result` blocks never appear, every request goes to the plan model, and the act routing never fires. Plan Mode is useful if you want the plan model to write out a full plan for your review before any execution begins, but that means only one model is ever used for that session.

**Important caveat**: Claude Code itself does not understand the `plan:X||act:Y` compound format. When it receives this as `ANTHROPIC_CUSTOM_MODEL_OPTION`, it rejects the compound string and falls back to `claude-sonnet-4-6`. The actual Plan/Act routing is done by the VK `model_override` in the Bifrost database, which intercepts the incoming model ID and substitutes the compound string at the Bifrost level — so Claude Code never sees it.

---

## Routing Rules — Traffic Distribution Across Providers

Bifrost routing rules control how requests are distributed across providers. Each rule has three parts:

1. **CEL expression** — matching logic (e.g. `model.contains("DeepSeek-V4-Flash")`)
2. **Targets** — weighted load distribution. The engine picks ONE target per request using weighted random selection.
3. **Fallbacks** — ordered retry chain on error. Applied regardless of which target was picked.

**Flow:**
```
Request → CEL match → select ONE target by weight → send request
                                                       ↓
                                               if error → fallback[0]
                                                              ↓
                                                       if error → fallback[1]...
```

**Key insight — Targets ≠ Fallbacks:**
- Targets distribute *first attempts* across providers by weight (e.g. Novita 80%, Parasail 10%, DeepInfra 10%)
- Fallbacks are the *retry order* after the chosen target fails
- The chosen target is prepended to the fallback list automatically

This is useful for using cheaper or faster providers as the primary target, with reliable fallbacks when they error.

---

## Custom Provider Gotchas

When adding a new OpenAI-compatible inference provider through Bifrost's Web UI, several things are non-obvious:

1. **Provider name case is canonical** — the name you enter (e.g. `Novita`, `Moonshot`) is registered exactly as-is. Model ID prefixes in requests must match exactly (`Novita/...`, not `novita/...`).

2. **`base_url` must NOT include `/v1`** — Bifrost appends `/v1/[endpoint]` itself. Set `https://api.moonshot.ai`, not `https://api.moonshot.ai/v1`. Double `/v1/v1/` in error URLs is the symptom.

3. **Set `use_chat_completion_for_responses: true`** for any provider that doesn't implement the OpenAI Responses API (most do not). Without this, Bifrost sends to `/v1/responses` and the provider returns 400/404. The Web UI doesn't expose this field — it must be set via the database:

   ```sql
   UPDATE config_providers
   SET custom_provider_config_json = json_set(
     custom_provider_config_json,
     '$.use_chat_completion_for_responses',
     json('true')
   )
   WHERE name = 'ProviderName';
   ```

4. **Set `list_models: false` if your virtual key uses `["*"]` wildcard access** — when `list_models` is enabled and the VK uses `["*"]`, Bifrost validates every model against its internal catalog. New or custom models not in the catalog are rejected. The fix is the same database patch setting `allowed_requests.list_models = false`.

5. **Governance plugin restart required** — the governance plugin loads VK configs (provider allowlists, model allowlists) into memory at startup. Changes made via the Web UI or database to `governance_virtual_key_provider_configs` don't take effect until Bifrost is restarted. Symptom: "Model X is not allowed for this virtual key" despite `["*"]` being set.

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

**Symptom**: DeepSeek responses contained raw `<｜DSML｜`, `<｜function_call>` and `</｜function_call>` delimiter strings in the visible text output.

**Cause**: DeepSeek uses a proprietary DSML (DeepSeek Markup Language) format to delimit reasoning sections and tool calls in raw model output. The Parasail and Vertex AI MaaS providers surface this raw format through the OpenAI-compatible streaming layer. Bifrost was passing it through unmodified.

**Fix** (iterative — took several passes to get right):

1. Initial approach: regex-based stripping — worked for complete markers but missed markers split across SSE chunk boundaries.
2. Added a rolling byte buffer to catch markers split between two consecutive SSE events.
3. Final approach: centralized stateful suppression (`StripDeepSeekMarkersWithState` in `schemas/utils.go`). Once any DSML marker is detected, a suppression flag is set permanently for the lifetime of the stream. All subsequent text content is zeroed.

The centralized function is called from `HandleOpenAIChatCompletionStreaming` in `providers/openai/openai.go` and applies to all OpenAI-compatible provider paths.

---

### 4. Tool Call Arguments Dropped for DeepSeek and Qwen

**Symptom**: After the DSML suppression was in place, tool calls from DeepSeek and Qwen3.5 arrived with empty inputs.

**Cause**: The DSML suppression kill-switch (fix 3) zeroes *all* text content after the first DSML marker. This is correct for text output, but DeepSeek in thinking mode also emits `<｜function_call>` in the content stream *before* switching to proper tool-call deltas. Once suppression fires, tool argument chunks that arrive in subsequent text content events are also zeroed.

**Fix**: Rather than trying to distinguish "tool argument content" from "DSML content" in the suppression layer (which is fragile), disable thinking at source for the affected models. Added `injectThinkingDisable()` in the provider handler, called before the OpenAI handler:

- DeepSeek models: injects `chat_template_kwargs: {"thinking": false}`
- Qwen models: injects `chat_template_kwargs: {"enable_thinking": false}`

With thinking disabled at source, no DSML markers appear, the suppressor never fires, and tool arguments flow through intact.

---

### 5. Streaming Crash — Nil Pointer on Usage Block

**Symptom**: Intermittent nil-pointer panic in the Anthropic stream converter when a model returned a `message_delta` event without a usage block.

**Fix**: Added nil-guard before dereferencing the usage pointer. Ensured `message_delta` always carries a usage block in the outbound SSE event, even if upstream did not provide one.

---

### 6. `response.incomplete` Not Handled in Stream Converter

**Symptom**: Streams with `finish_reason=length` or `finish_reason=content_filter` (truncated responses) fell through to a `return nil` default in the stream event converter, silently dropping the stop event.

**Fix**: Added explicit handling for `response.incomplete` in the stream converter, mapping it to the appropriate `message_delta` stop event with `stop_reason=max_tokens`.

---

### 7. OpenAI-Compat Providers Without `/v1/responses` — 404 Errors

**Symptom**: Custom OpenAI-compatible providers (e.g. DeepInfra) returned 404 errors for every chat request routed through the Anthropic compat layer.

**Cause**: The Anthropic-to-OpenAI translation layer routes all requests through `ResponsesRequest`, which calls `POST /v1/responses` — an endpoint most third-party providers don't implement (DeepInfra only exposes standard Chat Completions at `/v1/chat/completions`). Providers like Parasail worked because they have native `Responses()` overrides that internally convert to a Chat Completion call; the base OpenAI provider does not.

A secondary issue: some providers expose their API at a path that already includes `/v1` (e.g. DeepInfra's base URL is `https://api.deepinfra.com/v1/openai`). Bifrost appends its own `/v1/models`, `/v1/chat/completions` etc., producing doubled paths. This is fixed via `request_path_overrides` in the provider's custom config.

**Fix**: Added `UseChatCompletionForResponses` to `CustomProviderConfig`. When set to `true`, the base OpenAI provider converts the request via `ToChatRequest()` and calls `ChatCompletion()` / `ChatCompletionStream()` instead of attempting a `/v1/responses` call. The flag is set per-provider in the database — no code changes per provider.

---

### 8. Plan/Act Model Routing for Agentic Tasks

**Motivation**: In a typical Claude Code agentic loop, the model alternates between two distinct cognitive modes — reasoning about what to do (planning) and executing tool calls (acting). These modes have different cost/quality tradeoffs: a strong reasoning model is valuable for planning; a fast, capable coder is better for mechanical execution. Normally Claude Code sends every request to the same model.

**Feature**: Support a compound model string in the format `plan:MODEL_A||act:MODEL_B`. When Bifrost receives a request with this model ID, it inspects the message history to determine which phase the current request represents:

- **Plan phase** — no `tool_result` blocks in any user message → route to `MODEL_A`
- **Act phase** — at least one `tool_result` block present in a user message → route to `MODEL_B`

The signal is the **last user message only** — not the full history. This means the routing resets correctly turn by turn: a plain-text follow-up question routes back to the plan model even mid-conversation, and the next batch of tool results routes back to the act model. The routing alternates naturally with the flow of the task rather than latching permanently to act after the first tool use.

**Note on routing mechanism**: Claude Code itself rejects the `plan:X||act:Y` compound format and falls back to `claude-sonnet-4-6`. Therefore, Plan/Act routing cannot use `ANTHROPIC_CUSTOM_MODEL_OPTION`. Instead, the compound string is set in the VK's `description` field as a `model_override` JSON object. Bifrost's virtual key matching substitutes the compound model ID *after* Claude Code has sent the request, so the client never sees the compound string. The VK description acts as the routing entry point.

**Choosing your Act partner wisely**: Plan/Act routing is powerful but requires care at the Act tier. The Act model executes tool calls — file edits, shell commands, git operations. A model with heavy reasoning tendencies will waste cycles contemplating each `rm` before running it. The best Act partners are fast, decisive, and don't overthink mechanical steps. Newer MoE architectures (Mixture of Experts) are particularly well-suited here — they activate only relevant parameters per token, giving good speed and quality without the deliberation overhead of dense reasoning models. DeepSeek V4 Flash is a strong example: fast, capable with tools, and doesn't philosophise about `rm -rf`.

**Real-world example**: GLM 5.1 used as a Plan model with GitNexus to review an entire codebase. The Plan model analysed the code graph, identified architectural patterns, spotted issues, and produced a structured report. The Act model then executed the actual edits — file changes, refactors, git commits — based on the Plan model's analysis. The division of labour meant the reviewer (Plan) had full context, while the executor (Act) worked decisively without re-analysing the whole codebase on every tool call.

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

The `RequestConverter` calls `parsePlanActModel` on every incoming request. If parsing succeeds, `hasToolResultBlocks` selects the target model before the request is converted. Non-compound model strings pass through unchanged.

**Example** (set in VK `model_override`):
```
plan:Deepinfra/moonshotai/Kimi-K2.6||act:nebius/deepseek-ai/DeepSeek-V3.2
```

Plan turns route to Kimi K2.6 (strong reasoning); act turns route to DeepSeek V3.2 (fast coder). The full conversation history is forwarded on every request, so the act model always has the plan model's reasoning in context.

**Claude Code mode matters**: For the act model to be invoked, use normal "Ask before edits" mode — tool results accumulate as the agentic loop runs and trigger the switch to the act model. In explicit Plan Mode, Claude Code never emits tool calls, so `tool_result` blocks never appear and every request goes to the plan model.

---

### 9. Haiku Model Interception for Session Titles

**Symptom**: Session title generation failed with `500` errors when using non-Anthropic providers.

**Cause**: Claude Code hardcodes `claude-haiku-4-5-20251001` for session title generation, ignoring `ANTHROPIC_CUSTOM_MODEL_OPTION`. This bare `claude-*` model ID hits Bifrost without a provider prefix, and Bifrost's `ParseModelString` defaults unprefixed `claude-*` IDs to the Anthropic provider. If the Anthropic provider key is not configured (or intentionally disabled for cost control), the title request fails with a 500 error after multiple retries.

**Fix**: The VK `model_override` intercepts the bare `claude-haiku-4-5-20251001` before it reaches the routing layer and substitutes the configured plan model. As long as a valid `model_override` is set in the VK description, session title calls succeed silently — the Haiku ID never actually routes to Haiku.

---

## Current State

All Claude Code agentic features tested and working through Bifrost:

| Feature | Status |
|---|---|
| Basic chat (streaming) | ✅ |
| Tool use (Bash, Read, Write, Edit) | ✅ Qwen3.5, DeepSeek, Kimi, Gemini |
| Plan Mode | ✅ |
| Multi-step agentic tasks | ✅ |
| `count_tokens` preflight | ✅ stub |
| Thinking/reasoning suppression | ✅ |
| DSML marker stripping | ✅ |
| Custom provider Chat Completion fallback | ✅ `UseChatCompletionForResponses` flag |
| Plan/Act model routing | ✅ compound model string via VK `model_override` |
| Session title generation | ✅ VK interception of hardcoded Haiku ID |

**Providers tested**:
- Parasail — Qwen3.5, Gemma 4 26B, DeepSeek V3.2, Kimi K2.6
- Google — Gemini 3 Flash Preview
- Vertex AI MaaS — DeepSeek V3.2, Gemma 4 26B, GLM-5
- DeepInfra — DeepSeek V3.2, DeepSeek V4 Flash, Kimi K2.6
- Nebius AI Studio — DeepSeek V3.2, MiniMax M2.5
- Novita — DeepSeek V4 Flash, Kimi K2.6
- Moonshot — Kimi K2.6

**Known limitations**:
- Switching a conversation from Bifrost-routed models back to direct Anthropic can cause 400 errors: Bifrost responses may include content types (e.g. `redacted_thinking`) that Anthropic's SDK rejects when the same conversation continues on the Anthropic API. Start a new conversation after switching back.
- Subagent calls (e.g. `Agent(subagent_type="Explore")`) inherit `ANTHROPIC_BASE_URL` and route through Bifrost — they don't silently fall through to Anthropic.
- Some provider-specific model capabilities (web search, citations) only work with Claude models on the Anthropic API — these are not available through Bifrost routing to non-Claude models.

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

**Podman equivalent** (rootless):
```bash
podman build -t bifrost:claude-code-compat -f transports/Dockerfile.local .
podman rm -f bifrost
podman run -d --restart=always --network=host --name=bifrost --userns=keep-id \
  -e APP_PORT=8787 -e APP_HOST=0.0.0.0 \
  -e PARASAIL_API_KEY="..." \
  -e GOOGLE_GEMINI_API_KEY="..." \
  -v /path/to/bifrost/data:/app/data \
  bifrost:claude-code-compat
```

`--userns=keep-id` is required for rootless Podman — without it, UID remapping denies access to the data volume.
