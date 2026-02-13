#!/usr/bin/env bash
# =============================================================================
# LiteLLM Proxy Setup Script
#
# Usage:
#   git clone https://github.com/Counterweight-AI/litellm.git
#   cd litellm
#   ./setup.sh
#
# This script:
#   1. Checks for Python 3.10+
#   2. Creates a virtual environment
#   3. Installs LiteLLM with proxy support
#   4. Patches the proxy config for the current machine
#   5. Prompts for API keys and writes a .env file
#   6. Starts the proxy on port 4141
# =============================================================================
#set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$REPO_ROOT/litellm/proxy/proxy_config.yaml"
ROUTING_RULES="$REPO_ROOT/litellm/router_strategy/auto_router/routing_rules.yaml"
VENV_DIR="$REPO_ROOT/.venv"
ENV_FILE="$REPO_ROOT/.env"
MODELS_FILE="$REPO_ROOT/models.yaml"

MIN_PY_MINOR=10  # Python 3.10+ required (mcp, python-multipart, polars need it)
MAX_PY_MINOR=13  # Python 3.14+ breaks uvloop; cap at 3.13

# ---------- helpers ----------------------------------------------------------

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# Cross-platform sed -i (GNU vs BSD/macOS)
sedi() {
    if sed --version &>/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# ---------- 0. Validate required environment variables ----------------------
MISSING=""
[ -z "${GOOGLE_API_KEY:-}" ]        && MISSING="$MISSING GOOGLE_API_KEY"
[ -z "${AWS_ACCESS_KEY_ID:-}" ]     && MISSING="$MISSING AWS_ACCESS_KEY_ID"
[ -z "${AWS_SECRET_ACCESS_KEY:-}" ] && MISSING="$MISSING AWS_SECRET_ACCESS_KEY"
[ -z "${AWS_REGION_NAME:-}" ]       && MISSING="$MISSING AWS_REGION_NAME"
[ -z "${BEDROCK_API_KEY:-}" ]       && MISSING="$MISSING BEDROCK_API_KEY"
if [ -n "$MISSING" ]; then
    echo "ERROR: Missing required environment variables:$MISSING"
    exit 1
fi

# ---------- 1. Python check -------------------------------------------------

echo ""
echo -e "${BOLD}=== LiteLLM Proxy Setup ===${NC}"
echo ""

info "Checking for Python 3.${MIN_PY_MINOR}–3.${MAX_PY_MINOR}..."

# Search order: versioned binaries first (most precise), then homebrew/pyenv,
# then generic names. This avoids macOS system 3.9 and bleeding-edge 3.14+.
PYTHON=""
for candidate in \
    python3.13 python3.12 python3.11 python3.10 \
    /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    "$HOME/.pyenv/shims/python3" \
    python3 python; do
    if command -v "$candidate" &>/dev/null; then
        PY_MAJOR=$("$candidate" -c 'import sys; print(sys.version_info.major)' 2>/dev/null || echo 0)
        PY_MINOR=$("$candidate" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)
        if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ge "$MIN_PY_MINOR" ] && [ "$PY_MINOR" -le "$MAX_PY_MINOR" ]; then
            PYTHON="$candidate"
            break
        fi
    fi
done

if [ -z "$PYTHON" ]; then
    echo ""
    fail "Python 3.${MIN_PY_MINOR}–3.${MAX_PY_MINOR} is required but not found.

  - Python < 3.10 is missing required packages (mcp, python-multipart).
  - Python 3.14+ is not yet supported (uvloop incompatibility).

  Install a supported version:
    macOS:   brew install python@3.12
    Ubuntu:  sudo apt install python3.12 python3.12-venv
    Any:     https://www.python.org/downloads/

  Then re-run: ./setup.sh"
fi

PY_VERSION=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')
ok "Found $PYTHON ($PY_VERSION)"

# ---------- 2. Virtual environment ------------------------------------------

info "Setting up virtual environment..."

if [ ! -d "$VENV_DIR" ]; then
    "$PYTHON" -m venv "$VENV_DIR"
    ok "Created virtual environment at .venv/"
else
    ok "Virtual environment already exists at .venv/"
fi

# Activate
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# Bootstrap pip if missing (Debian/Ubuntu without python3.XX-venv package)
if ! python -c "import pip" 2>/dev/null; then
    warn "pip not found in venv — bootstrapping via get-pip.py"
    GET_PIP_URL="https://bootstrap.pypa.io/get-pip.py"
    GET_PIP_PATH="$VENV_DIR/get-pip.py"
    if command -v curl &>/dev/null; then
        curl -sSL "$GET_PIP_URL" -o "$GET_PIP_PATH" || fail "Failed to download get-pip.py"
    elif command -v wget &>/dev/null; then
        wget -q "$GET_PIP_URL" -O "$GET_PIP_PATH" || fail "Failed to download get-pip.py"
    else
        fail "Neither curl nor wget found — cannot bootstrap pip"
    fi
    python "$GET_PIP_PATH" --quiet || fail "get-pip.py failed"
    rm -f "$GET_PIP_PATH"
    ok "Bootstrapped pip via get-pip.py"
fi

# ---------- 3. Install -------------------------------------------------------

info "Upgrading pip..."
python -m pip install --upgrade pip --quiet

info "Installing LiteLLM with proxy extras (this may take a minute)..."
python -m pip install -e "$REPO_ROOT[proxy]" 2>&1 | tail -5

# Verify the install
if ! command -v litellm &>/dev/null; then
    fail "litellm CLI not found after install. Check the output above for errors."
fi

LITELLM_VERSION=$(python -c 'from importlib.metadata import version; print(version("litellm"))' 2>/dev/null || echo "unknown")
ok "Installed litellm $LITELLM_VERSION"

# ---------- 4. Patch proxy config -------------------------------------------

info "Configuring proxy config for this machine..."

if [ ! -f "$CONFIG_FILE" ]; then
    fail "Proxy config not found at $CONFIG_FILE"
fi

if [ ! -f "$ROUTING_RULES" ]; then
    fail "Routing rules not found at $ROUTING_RULES"
fi

# Fix the auto_router_config_path to point to this clone's absolute path
sedi "s|auto_router_config_path:.*|auto_router_config_path: \"$ROUTING_RULES\"|" "$CONFIG_FILE"
ok "Updated auto_router_config_path -> $ROUTING_RULES"

# Disable mcp_semantic_tool_filter (requires optional semantic-router package)
sedi "s|enabled: true|enabled: false|" "$CONFIG_FILE"
ok "Disabled mcp_semantic_tool_filter (enable after: pip install 'litellm[semantic-router]')"

# ---------- 5. API keys (.env) ----------------------------------------------
GOOGLE_KEY="${GOOGLE_API_KEY:-}"
OPENAI_KEY="" ANTHROPIC_KEY=""
DEEPSEEK_KEY="" MOONSHOT_KEY="" ZAI_KEY="" XAI_KEY="" MINIMAX_KEY=""

if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<EOF
# Auto-generated (headless mode)
GOOGLE_API_KEY=${GOOGLE_API_KEY:-}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}
AWS_REGION_NAME=${AWS_REGION_NAME:-}
BEDROCK_API_KEY=${BEDROCK_API_KEY:-}
EOF
    ok "Created .env from environment variables"
else
    ok ".env already exists — using existing file"
fi

# ---------- 5b. Set auto-router tier models ---------------------------------
info "Setting tier models in routing_rules.yaml..."
sedi '/^  low:/,/^  [a-z]/{s|model:.*|model: "gemini/gemini-3-flash-preview"|;}' "$ROUTING_RULES"
sedi '/^  mid:/,/^  [a-z]/{s|model:.*|model: "gemini/gemini-3-pro-preview"|;}' "$ROUTING_RULES"
sedi '/^  top:/,/^[a-z]/{s|model:.*|model: "bedrock/us.anthropic.claude-opus-4-6-v1"|;}' "$ROUTING_RULES"
ok "Tier models: low=gemini-3-flash, mid=gemini-3-pro, top=opus-4-6"

# ---------- 5c. Add provider models to proxy_config.yaml --------------------

# Collect model entries to add, then insert them all at once before "auto".
_NEW_MODELS_FILE=$(mktemp)
trap 'rm -f "$_NEW_MODELS_FILE"' EXIT

# Queue a model entry (written to temp file, inserted later in one pass).
add_model() {
    local model_name="$1" model_id="$2" api_key_env="$3"
    # Skip if already in the config
    if grep -q "model_name: $model_name" "$CONFIG_FILE" 2>/dev/null; then
        return 0
    fi
    cat >> "$_NEW_MODELS_FILE" <<ENTRY

  - model_name: $model_name
    litellm_params:
      model: $model_id
      api_key: os.environ/$api_key_env
ENTRY
    return 0
}

# Read provider models from models.yaml and queue entries for available providers
_PROVIDER_MODELS=$(MODELS_FILE="$MODELS_FILE" AVAILABLE="$AVAILABLE" python << 'PYEOF'
import yaml, os
providers = set(os.environ.get("AVAILABLE", "").split())
with open(os.environ["MODELS_FILE"]) as f:
    cfg = yaml.safe_load(f)
for name, info in cfg["provider_models"].items():
    if name in providers:
        for m in info["models"]:
            print(f'{m["name"]}|{m["id"]}|{info["key_env"]}')
PYEOF
)

if [ -n "$_PROVIDER_MODELS" ]; then
    while IFS='|' read -r _mname _mid _mkey; do
        add_model "$_mname" "$_mid" "$_mkey"
    done <<< "$_PROVIDER_MODELS"
fi

# Flush queued models into proxy_config.yaml
if [ -s "$_NEW_MODELS_FILE" ]; then
    # Convert empty YAML list to block-style so we can append entries
    if grep -q 'model_list: \[\]' "$CONFIG_FILE"; then
        sedi 's/model_list: \[\]/model_list:/' "$CONFIG_FILE"
    fi

    if grep -q '- model_name: auto' "$CONFIG_FILE"; then
        # Insert before the "auto" entry
        awk -v newfile="$_NEW_MODELS_FILE" '
            /^  - model_name: auto$/ {
                while ((getline line < newfile) > 0) print line
                close(newfile)
            }
            { print }
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        # No auto entry — append after "model_list:" line
        awk -v newfile="$_NEW_MODELS_FILE" '
            /^model_list:/ {
                print
                while ((getline line < newfile) > 0) print line
                close(newfile)
                next
            }
            { print }
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi
    ok "Added model(s) to proxy_config.yaml for configured providers"
else
    info "No new models to add to proxy_config.yaml"
fi
rm -f "$_NEW_MODELS_FILE"

# Ensure the "auto" model entry exists (uses the auto-router)
if ! grep -q 'model_name: auto' "$CONFIG_FILE"; then
    # Pick a default model: use the mid tier if set, otherwise first available provider model
    AUTO_DEFAULT="${MID_MODEL:-${LOW_MODEL:-${TOP_MODEL:-}}}"
    if [ -z "$AUTO_DEFAULT" ] && [ -n "$_PROVIDER_MODELS" ]; then
        AUTO_DEFAULT=$(echo "$_PROVIDER_MODELS" | head -1 | cut -d'|' -f2)
    fi
    AUTO_DEFAULT="${AUTO_DEFAULT:-gemini/gemini-3-flash-preview}"

    # Convert empty YAML list if not already done
    if grep -q 'model_list: \[\]' "$CONFIG_FILE"; then
        sedi 's/model_list: \[\]/model_list:/' "$CONFIG_FILE"
    fi

    # Append the auto entry at the end of model_list (before the next top-level key)
    awk -v routing="$ROUTING_RULES" -v default_model="$AUTO_DEFAULT" '
        /^model_list:/ { in_models=1 }
        in_models && (/^[a-z]/ || /^#/) && !/^model_list:/ {
            printf "\n  - model_name: auto\n"
            printf "    litellm_params:\n"
            printf "      model: \"auto_router/auto_router_1\"\n"
            printf "      auto_router_config_path: \"%s\"\n", routing
            printf "      auto_router_default_model: \"%s\"\n", default_model
            printf "\n"
            in_models=0
        }
        { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    ok "Added auto-router entry to proxy_config.yaml (default: $AUTO_DEFAULT)"
fi

# ---------- 5d. Register litellm provider with OpenClaw ---------------------

OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"

if [ -f "$OPENCLAW_CONFIG" ]; then
    info "Registering litellm provider in OpenClaw config..."
    python << 'PYEOF'
import json, os

config_path = os.path.expanduser("~/.openclaw/openclaw.json")
with open(config_path) as f:
    config = json.load(f)

# Ensure models.providers path exists
config.setdefault("models", {})
config["models"].setdefault("providers", {})

config["models"]["providers"]["litellm"] = {
    "baseUrl": "http://127.0.0.1:4141/v1",
    "apiKey": "sk-1234",
    "api": "openai-completions",
    "models": [
        {
            "id": "auto",
            "name": "LiteLLM Auto",
            "reasoning": False,
            "input": ["text"],
            "cost": {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0
            },
            "contextWindow": 128000,
            "maxTokens": 8192
        }
    ]
}

# Set litellm/auto as the primary model
config.setdefault("agents", {})
config["agents"].setdefault("defaults", {})
old_primary = config["agents"]["defaults"].get("model", {}).get("primary")
config["agents"]["defaults"]["model"] = {
    "primary": "litellm/auto",
}
if old_primary and old_primary != "litellm/auto":
    config["agents"]["defaults"]["model"]["fallbacks"] = [old_primary]

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
    ok "Added litellm provider with auto model to $OPENCLAW_CONFIG"
else
    info "OpenClaw not found (~/.openclaw/openclaw.json missing) — skipping provider registration"
fi

# ---------- 6. Start proxy ---------------------------------------------------

echo ""
echo -e "${BOLD}=== Starting LiteLLM Proxy ===${NC}"
echo ""
echo -e "  Config : ${CYAN}$CONFIG_FILE${NC}"
echo -e "  Port   : ${CYAN}4141${NC}"
echo -e "  Key    : ${CYAN}sk-1234${NC}  (set in config litellm_settings.master_key)"
echo ""
echo -e "${BOLD}Test it:${NC}"
echo ""
echo "  # Health check"
echo "  curl http://localhost:4141/health"
echo ""
echo "  # Chat completion via the auto-router"
echo '  curl http://localhost:4141/v1/chat/completions \'
echo '    -H "Content-Type: application/json" \'
echo '    -H "Authorization: Bearer sk-1234" \'
echo '    -d '"'"'{"model":"auto","messages":[{"role":"user","content":"Hello!"}]}'"'"
echo ""
echo -e "${GREEN}Starting...${NC}"
echo ""

# Load env vars
set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a

# Kill any existing process on port 4141
PORT=4141
EXISTING_PID=$(lsof -ti:$PORT 2>/dev/null)
if [ -n "$EXISTING_PID" ]; then
    warn "Killing existing process on port $PORT (PID: $EXISTING_PID)"
    kill "$EXISTING_PID" 2>/dev/null
    sleep 1
    # Force kill if still running
    if kill -0 "$EXISTING_PID" 2>/dev/null; then
        kill -9 "$EXISTING_PID" 2>/dev/null
    fi
    ok "Port $PORT cleared"
fi

exec ./.venv/bin/litellm --config "$CONFIG_FILE" --port 4141
