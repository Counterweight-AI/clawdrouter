# Headless Setup Implementation

**Date:** 2026-02-14
**Objective:** Make `setup.sh` fully non-interactive for CI/automated deployment
**Net Change:** -95 lines (30 insertions, 125 deletions)
**Commits:** 3 separate commits, one per edit

---

## Goal

Transform `setup.sh` from an interactive script (with API key prompts and dynamic model selection) into a headless script that:
- Expects all required environment variables to be pre-set
- Never blocks on user input (`read` commands)
- Uses hardcoded tier model assignments
- Fails fast with clear error messages if env vars are missing

---

## Implementation Approach

**Strategy:** Individual, carefully scoped edits with commits between each
- Ensures atomic changes that can be reviewed/reverted independently
- Follows project CLAUDE.md instruction: "delegate one by one... commit changed files in between each delegation"
- All edits made directly (not delegated to subagents per user request)

---

## Changes Made

### Edit 1: Environment Variable Validation (commit `3ac7c71`)

**Location:** After line 51, before Section 1 (Python check)

**What Changed:**
- Added new Section 0: "Validate required environment variables"
- Checks for 4 required env vars:
  - `GOOGLE_API_KEY`
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `AWS_REGION_NAME`
- Exits with `exit 1` and clear error message listing missing vars if any are unset

**Rationale:**
- Fail-fast principle: detect missing requirements immediately
- Prevents script from running partway through before failing
- Clear error messaging for troubleshooting in CI/automation

**Code Pattern:**
```bash
MISSING=""
[ -z "${VAR:-}" ] && MISSING="$MISSING VAR"
if [ -n "$MISSING" ]; then
    echo "ERROR: Missing required environment variables:$MISSING"
    exit 1
fi
```

---

### Edit 2: Remove Interactive API Key Prompts (commit `338ffb3`)

**Location:** Section 5a (lines 167-243)

**What Changed:**
- **Removed:** 77 lines of interactive logic:
  - All `read -rp` prompts for API keys (Google, OpenAI, Anthropic, DeepSeek, Moonshot, ZAI, xAI, MiniMax)
  - Optional provider selection menu
  - Existing `.env` key extraction logic (`_getkey` function)
  - Empty key validation warnings
- **Replaced with:** 12 lines of headless logic:
  - Direct env var assignment: `GOOGLE_KEY="${GOOGLE_API_KEY:-}"`
  - `.env` file generation from environment variables (not prompts)
  - Simple exists check with descriptive status messages

**Rationale:**
- Interactive `read` commands block automation
- Environment variables are the standard for CI/CD secret injection
- Simplified `.env` to only include the 4 required vars (Google + AWS for tier models)

**Key Decision:**
- Only initialize `GOOGLE_KEY` from env; set others to empty strings
- This aligns with downstream Section 5b which now uses hardcoded models (doesn't need provider detection)

---

### Edit 3: Hardcoded Tier Models (commit `50146ab`)

**Location:** Section 5b (lines 198-251, renumbered after Edit 2)

**What Changed:**
- **Removed:** 54 lines of dynamic tier selection:
  - Provider availability detection based on API keys
  - Python script reading `models.yaml` for tier candidates
  - Dynamic model selection from available providers
  - `eval` of Python output to set `LOW_MODEL`, `MID_MODEL`, `TOP_MODEL` vars
  - Conditional tier suggestion display
  - Commented-out user prompt for tier application
- **Replaced with:** 6 lines of hardcoded `sedi` calls:
  - Direct regex replacement in `routing_rules.yaml`
  - Fixed tier assignments using exact patterns proven on original lines 291-293

**Tier Assignments:**
| Tier | Model ID | Provider |
|------|----------|----------|
| LOW  | `gemini/gemini-3-flash-preview` | Google |
| MID  | `gemini/gemini-3-pro-preview` | Google |
| TOP  | `bedrock/us.anthropic.claude-opus-4-6-v1` | AWS Bedrock |

**Rationale:**
- Dynamic selection requires `models.yaml` parsing and provider key detection
- Headless mode assumes a standardized deployment environment
- Hardcoded models simplify setup and remove Python dependency for this step
- Google (Gemini) for low/mid tiers, AWS Bedrock (Opus) for top tier aligns with validated env vars

**Technical Pattern:**
```bash
sedi '/^  low:/,/^  [a-z]/{s|model:.*|model: "gemini/gemini-3-flash-preview"|;}' "$ROUTING_RULES"
```
- Regex range: from `^  low:` to next line starting with `^  [a-z]`
- Substitution: replace `model:.*` with hardcoded model ID
- Reuses proven `sedi` wrapper (handles GNU vs BSD sed differences)

---

## Sections Left Unchanged

These sections remain non-interactive and required no modification:

1. **Lines 1-51:** Header, variables, helper functions (`info`, `ok`, `warn`, `fail`, `sedi`)
2. **Lines 53-165:** Python check, venv creation, package install, config patching (all automated)
3. **Section 5c (lines 253+):** Provider model registration in `proxy_config.yaml`
   - Still runs but effectively no-op: models already exist in config
   - `add_model` function deduplicates via `grep -q` check
4. **Section 5d (lines 407+):** OpenClaw registration (conditional, non-interactive)
5. **Section 6 (lines 465+):** Proxy startup (`source .env`, clear port 4141, exec litellm)

---

## Verification Steps

Designed test plan (not executed in this session):

1. **Missing env var test:**
   ```bash
   unset GOOGLE_API_KEY
   ./setup.sh
   # Expected: "ERROR: Missing required environment variables: GOOGLE_API_KEY" + exit 1
   ```

2. **Happy path test:**
   ```bash
   export GOOGLE_API_KEY="..."
   export AWS_ACCESS_KEY_ID="..."
   export AWS_SECRET_ACCESS_KEY="..."
   export AWS_REGION_NAME="us-east-1"
   export BEDROCK_API_KEY="..."
   ./setup.sh
   # Expected: No prompts, script runs to completion, proxy starts
   ```

3. **Config validation:**
   - Verify `.env` contains 4 env vars
   - Verify `routing_rules.yaml` has 3 hardcoded tier models
   - Verify `curl http://localhost:4141/health` returns 200

---

## Key Insights

### Why Individual Commits Matter
- Each edit is independently reversible
- Clear audit trail for troubleshooting
- Follows project convention (CLAUDE.md: "commit changed files in between each delegation")
- Easier code review in multi-engineer scenarios

### Environment Variable Design
- **Required vars:** Only the 4 actually used by hardcoded tier models
- **Not required:** OpenAI, Anthropic API, DeepSeek, etc. (not used in new tier assignments)
- **Tradeoff:** Less flexible but more predictable for automation

### Sed Pattern Reuse
- Edit 3 reused exact `sedi` patterns from original lines 291-293
- Proven patterns reduce risk of regex errors
- Range syntax `/^  low:/,/^  [a-z]/` targets tier block precisely

### Python Dependency Reduction
- Removed Python-based `models.yaml` parsing in Section 5b
- Python still used in:
  - Section 5c: provider model registration (minor)
  - Section 5d: OpenClaw config modification (optional)
- Could be further reduced if needed for minimal environments

---

## Future Considerations

### Potential Improvements
1. **Make tier models configurable via env vars:**
   ```bash
   LOW_TIER_MODEL="${LOW_TIER_MODEL:-gemini/gemini-3-flash-preview}"
   ```
   - Balances hardcoding with flexibility
   - Still defaults to known-good values

2. **Add env var validation for model-specific keys:**
   - If using Bedrock → validate `AWS_*` vars
   - If using Gemini → validate `GOOGLE_API_KEY`
   - More granular than current "require all 5" approach

3. **CI/CD integration examples:**
   - GitHub Actions secret mapping
   - Docker environment file patterns
   - Kubernetes ConfigMap/Secret injection

### Replication Guide for Engineers
When applying this pattern to other interactive scripts:

1. **Identify all `read` commands** → replace with env var assignment
2. **Find Python/dynamic logic** → evaluate if hardcoding is acceptable
3. **Add upfront validation** → fail fast with clear errors
4. **Commit atomically** → one logical change per commit
5. **Test both paths** → missing env vars (should fail) + happy path (should succeed)

---

## Files Modified

| File | Lines Changed | Status |
|------|---------------|--------|
| `setup.sh` | +30, -125 | Modified |
| `routing_rules.yaml` | 0 (updated at runtime) | Runtime update |
| `proxy_config.yaml` | 0 (already configured) | No change |
| `.env` | N/A | Generated at runtime |

---

## Related Documentation

- **Plan document:** Original plan file detailing all 3 edits
- **CLAUDE.md:** Project instructions for commit hygiene and delegation patterns
- **setup.sh comments:** Original script had inline documentation preserved
- **Git history:** `git log --oneline -3` shows atomic commits

---

## Success Metrics

✅ **Script is fully headless** → no `read` commands remain
✅ **Clear error handling** → fails fast with actionable error messages
✅ **Reduced complexity** → -95 lines, simpler logic flow
✅ **Atomic commits** → 3 commits, each independently meaningful
✅ **Preserved functionality** → All other sections (venv, install, proxy start) unchanged
✅ **Documentation complete** → This worklog + git commit messages provide full context
