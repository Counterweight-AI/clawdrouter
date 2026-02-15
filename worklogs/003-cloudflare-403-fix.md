# 001: Cloudflare 403 Fix

## Problem Statement

OpenClaw AI application worked correctly when connecting to local LiteLLM proxy (`localhost:4141`) but consistently failed with "no response" error when connecting to the identical codebase deployed remotely at `https://router.counterweightai.com/v1` behind Cloudflare Tunnel.

## Root Cause Analysis

**Primary Issue:** Cloudflare Bot Fight Mode blocking `User-Agent: OpenAI/JS 6.10.0`

- OpenAI Node.js SDK (v6.10.0) used by OpenClaw's `@mariozechner/pi-ai` library automatically sets this User-Agent header
- Cloudflare's Bot Fight Mode (NOT WAF managed rules) blocks requests with `User-Agent` pattern matching `OpenAI/*`
- Response: `403 Forbidden` with `text/plain` body "Your request was blocked."
- Diagnostic evidence: Session logs at `/home/ubuntu/.openclaw/agents/main/sessions/probe-clawdrouter-*.jsonl` showed `"errorMessage":"403 Your request was blocked."`
- Model listing endpoint worked because it may use different code path or caching
- Local connections bypassed Cloudflare entirely, hence worked

**Secondary Issues (Streaming):**
- No SSE anti-buffering headers (`X-Accel-Buffering: no`) → reverse proxies buffer responses
- Uvicorn default keepalive timeout (5s) too short for long SSE connections through Cloudflare Tunnel (100s idle timeout)
- Time-to-first-token delays (especially Claude Opus) can exceed Cloudflare's idle connection timeout

## Solution Implemented

### 1. User-Agent Header Override (Immediate Fix)

**File:** `/home/ubuntu/.openclaw/openclaw.json`

Added custom `User-Agent` header to model configuration:
```json
"models": [{
  "id": "auto",
  "headers": {"User-Agent": "ClawRouter/1.0"},
  ...
}]
```

**How it works:**
- OpenAI SDK's `buildHeaders()` function merges headers in order (verified in `openai/src/client.ts:922-937`)
- `defaultHeaders` (index 4) override earlier SDK-set `User-Agent` (index 2)
- Custom User-Agent reaches Cloudflare instead of blocked `OpenAI/JS 6.10.0`
- Verification: `curl -H "User-Agent: ClawRouter/1.0" https://router.counterweightai.com/v1/models` returns 200 OK

### 2. SSE Anti-Buffering Headers

**File:** `litellm/proxy/common_request_processing.py` (line 437-439)

Modified `get_custom_headers()` method:
```python
"X-Accel-Buffering": "no",
"Cache-Control": "no-cache, no-transform",
```

**Purpose:**
- Prevents Cloudflare/nginx/reverse proxies from buffering SSE streams
- Ensures real-time chunk forwarding for streaming responses
- Critical for LLM inference where tokens stream incrementally

### 3. Increased Uvicorn Timeout

**File:** `clawrouter.service` (line 13)

Modified `ExecStart` command:
```bash
ExecStart=...litellm --config ... --port 4141 --timeout 600
```

**Purpose:**
- Increases keepalive from 5s default to 600s
- Prevents premature connection closure during long inference calls
- Accommodates Cloudflare Tunnel's 100s idle timeout + upstream LLM latency

### 4. Eliminated Local Proxy Dependency

**File:** `/home/ubuntu/.openclaw/openclaw.json`

Changes:
- Removed `litellm` provider entry (localhost:4141)
- Changed default model: `litellm/auto` → `clawdrouter/auto`
- Ensures exclusive use of remote endpoint

## Key Insights

### Cloudflare Bot Fight Mode vs WAF
- Bot Fight Mode blocks at edge before reaching origin (text/plain response)
- WAF managed rules return HTML challenge pages with JavaScript
- Bot Fight Mode found under **Security > Bots**, NOT Security > WAF
- User-Agent pattern `OpenAI/*` is explicitly blocked by Bot Fight Mode

### OpenAI SDK Header Precedence
- SDK merges headers via `buildHeaders([...arrays])` function
- Later array entries override earlier entries (by lowercased header name)
- `defaultHeaders` parameter effectively overrides SDK defaults
- Verified in: `openai/src/internal/headers.ts:71-92` (delete-then-replace logic)

### Streaming SSE Requirements
- SSE through reverse proxies requires explicit anti-buffering headers
- Cloudflare Tunnel adds latency + idle timeout constraints
- Time-to-first-token (TTFT) is critical bottleneck for reasoning models
- LiteLLM's `create_response()` awaits first chunk before streaming starts (line 141 in `common_request_processing.py`)

## Deployment Checklist

### Local Machine (This Machine) ✅
- [x] User-Agent override in OpenClaw config
- [x] Removed local proxy dependency
- [x] SSE headers added to codebase
- [x] Timeout flag added to service file

### Remote Server (router.counterweightai.com) 🔄
- [ ] Deploy code changes (SSE headers + timeout flag)
- [ ] Run: `sudo systemctl daemon-reload`
- [ ] Run: `sudo systemctl restart clawrouter`
- [ ] Verify: `curl -v https://router.counterweightai.com/v1/models` includes new headers

### Cloudflare Dashboard (Optional) 🔄
- [ ] Go to **Security > Bots** (NOT WAF)
- [ ] Disable **Bot Fight Mode** for `router.counterweightai.com`
- [ ] OR create WAF Custom Rule: Skip Bot Fight Mode for hostname
- [ ] Allows original OpenAI SDK User-Agent without client-side workaround

### Verification Testing 🔄
- [ ] Restart OpenClaw (or reload config)
- [ ] Send test message via `clawdrouter/auto`
- [ ] Verify streaming response completes (no 403, no timeout)
- [ ] Confirm no fallback to localhost in logs
- [ ] Test with reasoning tasks (Claude Opus) to verify TTFT handling

## Files Modified

| File | Lines | Change Type |
|------|-------|-------------|
| `/home/ubuntu/.openclaw/openclaw.json` | 28-44, 71-75 | User-Agent header, removed litellm provider, changed default model |
| `litellm/proxy/common_request_processing.py` | 437-439 | Added SSE anti-buffering headers |
| `clawrouter.service` | 13 | Added --timeout 600 flag |

## Technical References

- OpenAI SDK client: `/home/ubuntu/.nvm/versions/node/v22.22.0/lib/node_modules/openclaw/node_modules/openai/src/client.ts`
- Header builder: `/home/ubuntu/.nvm/versions/node/v22.22.0/lib/node_modules/openclaw/node_modules/openai/src/internal/headers.ts`
- OpenClaw provider handler: `/home/ubuntu/.nvm/versions/node/v22.22.0/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/providers/openai-completions.js`
- LiteLLM streaming: `litellm/proxy/common_request_processing.py:141` (create_response function)
- LiteLLM constants: `litellm/constants.py:307` (default request_timeout: 6000s)

## Scaling Considerations

### For Multiple OpenClaw Instances
1. Template the User-Agent override in OpenClaw deployment configs
2. Consider adding User-Agent to OpenClaw's default model templates
3. Document the Cloudflare Bot Fight Mode requirement in setup guides

### For ClawRouter Deployments
1. Include SSE headers in default proxy configuration
2. Set `--timeout 600` as standard in systemd service templates
3. Add Cloudflare Bot Fight Mode check to deployment verification scripts

### For Alternative Reverse Proxies
- Nginx: Requires `proxy_buffering off;` + `X-Accel-Buffering: no`
- Caddy: Automatically handles streaming (no config needed)
- HAProxy: Requires `option http-no-delay` + `no option http-buffer-request`

## Alternative Solutions Considered

1. **Cloudflare API-based WAF management** - Complex, requires API tokens, not sustainable at scale
2. **Client-side proxy/tunnel** - Adds latency, defeats purpose of remote deployment
3. **VPN/Tailscale** - Security overhead, doesn't solve Bot Fight Mode issue
4. **Custom fetch implementation** - Requires forking OpenAI SDK, maintenance burden
5. **Nginx reverse proxy on origin** - Adds complexity, doesn't solve root cause

**Selected approach:** User-Agent override is simplest, requires no infrastructure changes, works immediately

## Future Improvements

1. Submit PR to OpenClaw to support `headers` field in model configs (if not already supported)
2. Add Cloudflare-specific deployment documentation to ClawRouter README
3. Create automated test suite for streaming behavior through reverse proxies
4. Implement health check that validates both model listing AND streaming inference
5. Add monitoring for 403 errors and User-Agent patterns in production logs
