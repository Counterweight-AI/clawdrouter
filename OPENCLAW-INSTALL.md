# OpenClaw Installation Guide

## Method 1: Use Existing ClawRouter Instance

### Configuration
Add ClawRouter as a custom provider in OpenClaw:

- **Base URL:** `https://router.counterweightai.com`
- **API Key:** `sk-clawrouter` (or your custom `LITELLM_MASTER_KEY`)
- **Model:** `auto`

### Test
```bash
curl https://router.counterweightai.com/health

curl https://router.counterweightai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-clawrouter" \
  -d '{"model":"auto","messages":[{"role":"user","content":"Hello!"}]}'
```

## Method 2: Install as Plugin (Self-Hosted)

```bash
openclaw plugins install -l ./openclaw-plugin
# Restart gateway - plugin auto-configures and starts ClawRouter
```

**Plugin Config** (`openclaw.plugin.json`):
- `port`: 4141 (default)
- `masterKey`: "sk-clawrouter" (default)
- `gitRepo`: ClawRouter repo URL

The plugin automatically:
- Clones repo, installs dependencies
- Extracts API keys from OpenClaw auth profiles
- Generates configs and starts proxy
- Registers `clawrouter/auto` model

## Usage

**Auto-routing:**
```
"What is quantum computing?"
```
→ Response: `[low] ...` or `[med] ...` or `[high] ...`

**Force tier:**
```
"[high] Explain quantum entanglement in detail"
```

## Troubleshooting

- **Health check fails:** Verify ClawRouter is running, check firewall/network
- **401 Unauthorized:** Confirm API key matches `LITELLM_MASTER_KEY`
- **Model not found:** Ensure model name is `auto`, not `auto_router`
