# QUICKSTART.md

> Minimal setup guide for the Bifrost fork. For full context see [CLAUDE-CODE-COMPAT.md](CLAUDE-CODE-COMPAT.md).

## Prerequisites

- **Go 1.26.2+** (for building — or just use Docker/Podman)
- **Docker** or **Podman**
- **API keys** for at least one upstream provider (Novita, Parasail, DeepInfra, Moonshot, etc.)

## Build

```bash
git clone https://github.com/fjwood69/bifrost.git
cd bifrost
docker build -t bifrost:local -f transports/Dockerfile.local .
```

> The `.local` Dockerfile uses your local source tree. For production, use `transports/Dockerfile` (uses published module versions).

## Run

```bash
# Copy .env.example (or create one) with your provider API keys:
#   ANTHROPIC_API_KEY=sk-ant-...
#   OPENAI_API_KEY=sk-...
#   GOOGLE_GEMINI_API_KEY=...
#   (etc. — depends which providers you use)

docker run -d \
  --name bifrost \
  --restart unless-stopped \
  -p 8080:8080 \
  -v $(pwd)/data:/app/data \
  --env-file .env \
  bifrost:local
```

Bifrost stores configuration in a SQLite database at `/app/data/config.db`. On first run, it auto-creates the schema.

## Verify

```bash
# Health check
curl http://localhost:8080/health

# List available models
curl -s http://localhost:8080/v1/models | head -5

# Test with a Virtual Key
curl http://localhost:8080/v1/messages \
  -H "x-api-key: sk-bf-your-virtual-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"Hello"}]}'
```

## Next Steps

1. **Open the UI** at `http://localhost:8080` — set up providers, API keys, and routing rules
2. **Create Virtual Keys** — clients authenticate via VKs. Add one in the UI or via SQLite:
   ```sql
   INSERT INTO governance_virtual_keys (name, value, is_active)
   VALUES ('my-app', 'sk-bf-' || hex(randomblob(16)), 1);
   ```
3. **Add providers** — built-in providers (OpenAI, Anthropic, Google, Parasail, Nebius, etc.) just need an API key. Custom providers need base URL + `use_chat_completion_for_responses: true` in their config
4. **Configure routing** — CEL-based rules match model names to weighted provider targets
5. **Configure pricing** — pricing overrides in `governance_pricing_overrides` for cost tracking

## Key Fork Differences

The `claude-code-compat` branch adds:

- **Anthropic API emulation** — accept `/v1/messages` requests, translate to OpenAI-compatible calls
- **Virtual Key `model_override`** — reroute any model ID to a specific provider+model
- **Plan/Act routing** — different models for planning vs acting in Claude Code
- **Thinking block handling** — strip/suppress reasoning content for non-Anthropic providers
- **Chat Completion fallback** — `use_chat_completion_for_responses` flag for providers without `/v1/responses`

See [CLAUDE-CODE-COMPAT.md](CLAUDE-CODE-COMPAT.md) for the complete fix list.

## Troubleshooting

| Problem | Likely cause |
|---------|-------------|
| Provider returns 404 | `use_chat_completion_for_responses: true` missing in custom provider config |
| "$0.0000" costs | Pricing override missing or request_type mismatch |
| VK not matched | VK value sent in `x-api-key` header doesn't match DB |
| Config changes not picked up | Governance cache is loaded at startup — restart the container |
| Stream crashes mid-response | Nil-guard issue — check `message_delta` usage blocks in logs |
