#!/usr/bin/env bash
# =============================================================================
# LiteLLM Proxy Setup Script
#
# Usage:
#   ./setup.sh                      # Direct mode (no Docker), port 4141
#   ./setup.sh --port 4242          # Direct mode on custom port
#   ./setup.sh --docker             # Docker mode with per-user API keys, port 4141
#   ./setup.sh --docker --port 4343 # Docker mode on custom port
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
if [ -z "$REPO_ROOT" ]; then
    echo -e "${RED}[FAIL]${NC}  Failed to determine repository root directory" && exit 1
fi

CONFIG_FILE="$REPO_ROOT/litellm/proxy/proxy_config.yaml"
ROUTING_RULES="$REPO_ROOT/litellm/router_strategy/auto_router/routing_rules.yaml"
VENV_DIR="$REPO_ROOT/.venv"
ENV_FILE="$REPO_ROOT/.env"
MODELS_FILE="$REPO_ROOT/models.yaml"

# ---------- CLI flags ----------------------------------------------------------
DOCKER_MODE=false
PROXY_PORT=4141
while [ $# -gt 0 ]; do
    case "$1" in
        --docker) DOCKER_MODE=true ;;
        --port)
            shift
            PROXY_PORT="$1"
            if [ -z "$PROXY_PORT" ] || ! echo "$PROXY_PORT" | grep -qE '^[0-9]+$'; then
                fail "--port requires a numeric value (e.g. --port 4242)"
            fi
            ;;
    esac
    shift
done

MIN_PY_MINOR=10  # Python 3.10+ required (mcp, python-multipart, polars need it)
MAX_PY_MINOR=13  # Python 3.14+ breaks uvloop; cap at 3.13

# ---------- helpers ----------------------------------------------------------

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# Cross-platform sed -i (GNU vs BSD/macOS)
sedi() {
    local result
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
        result=$?
    else
        sed -i '' "$@"
        result=$?
    fi
    if [ $result -ne 0 ]; then
        echo -e "${RED}[FAIL]${NC}  sed operation failed on: ${*: -1}" && exit 1
    fi
    return 0
}

# ---------- 0. Validate required environment variables ----------------------
MISSING=""
[ -z "${GOOGLE_API_KEY:-}" ]        && MISSING="$MISSING GOOGLE_API_KEY"
[ -z "${AWS_ACCESS_KEY_ID:-}" ]     && MISSING="$MISSING AWS_ACCESS_KEY_ID"
[ -z "${AWS_SECRET_ACCESS_KEY:-}" ] && MISSING="$MISSING AWS_SECRET_ACCESS_KEY"
[ -z "${AWS_REGION_NAME:-}" ]       && MISSING="$MISSING AWS_REGION_NAME"
if [ -n "$MISSING" ]; then
    fail "Missing required environment variables:$MISSING

  Set these environment variables before running setup.sh:
    export GOOGLE_API_KEY='your-key-here'
    export AWS_ACCESS_KEY_ID='your-key-here'
    export AWS_SECRET_ACCESS_KEY='your-secret-here'
    export AWS_REGION_NAME='us-east-1'

  Then re-run: ./setup.sh"
fi

if [ "$DOCKER_MODE" = false ]; then

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
    if command -v "$candidate" >/dev/null 2>&1; then
        PY_MAJOR=$("$candidate" -c 'import sys; print(sys.version_info.major)' 2>&1)
        if [ $? -ne 0 ]; then
            warn "Failed to get version from $candidate, skipping..."
            continue
        fi
        PY_MINOR=$("$candidate" -c 'import sys; print(sys.version_info.minor)' 2>&1)
        if [ $? -ne 0 ]; then
            warn "Failed to get minor version from $candidate, skipping..."
            continue
        fi
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

PY_VERSION=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>&1)
if [ $? -ne 0 ]; then
    fail "Failed to get Python version from $PYTHON. Error: $PY_VERSION"
fi
ok "Found $PYTHON ($PY_VERSION)"

# ---------- 2. Virtual environment ------------------------------------------

info "Setting up virtual environment..."

if [ ! -d "$VENV_DIR" ]; then
    "$PYTHON" -m venv "$VENV_DIR"
    if [ $? -ne 0 ]; then
        fail "Failed to create virtual environment at $VENV_DIR

  Try installing python venv module:
    Ubuntu/Debian: sudo apt install python3-venv
    Fedora/RHEL:   sudo dnf install python3-venv

  Then re-run: ./setup.sh"
    fi
    ok "Created virtual environment at .venv/"
else
    ok "Virtual environment already exists at .venv/"
fi

# Activate
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
if [ $? -ne 0 ]; then
    fail "Failed to activate virtual environment at $VENV_DIR/bin/activate"
fi

# Bootstrap pip if missing (Debian/Ubuntu without python3.XX-venv package)
if ! python -c "import pip" 2>/dev/null; then
    warn "pip not found in venv — bootstrapping via get-pip.py"
    GET_PIP_URL="https://bootstrap.pypa.io/get-pip.py"
    GET_PIP_PATH="$VENV_DIR/get-pip.py"
    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$GET_PIP_URL" -o "$GET_PIP_PATH"
        if [ $? -ne 0 ]; then
            fail "Failed to download get-pip.py from $GET_PIP_URL using curl"
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$GET_PIP_URL" -O "$GET_PIP_PATH"
        if [ $? -ne 0 ]; then
            fail "Failed to download get-pip.py from $GET_PIP_URL using wget"
        fi
    else
        fail "Neither curl nor wget found — cannot bootstrap pip

  Install curl or wget:
    Ubuntu/Debian: sudo apt install curl
    Fedora/RHEL:   sudo dnf install curl
    macOS:         curl is pre-installed

  Then re-run: ./setup.sh"
    fi
    python "$GET_PIP_PATH"
    if [ $? -ne 0 ]; then
        fail "get-pip.py execution failed. Check the output above for errors."
    fi
    rm -f "$GET_PIP_PATH"
    ok "Bootstrapped pip via get-pip.py"
fi

# ---------- 3. Install -------------------------------------------------------

info "Upgrading pip..."
python -m pip install --upgrade pip --quiet
if [ $? -ne 0 ]; then
    fail "Failed to upgrade pip. Check your network connection and try again."
fi

info "Installing LiteLLM with proxy extras (this may take a minute)..."
INSTALL_OUTPUT=$(python -m pip install -e "$REPO_ROOT[proxy]" 2>&1)
INSTALL_RESULT=$?
if [ $INSTALL_RESULT -ne 0 ]; then
    echo "$INSTALL_OUTPUT" | tail -20
    fail "Failed to install LiteLLM with proxy extras. Check the output above for errors."
fi
echo "$INSTALL_OUTPUT" | tail -5

# Verify the install
if ! command -v litellm >/dev/null 2>&1; then
    fail "litellm CLI not found after install. Check the output above for errors.

  The installation completed but the litellm command is not available.
  This may indicate an issue with the virtual environment or PATH."
fi

LITELLM_VERSION=$(python -c 'from importlib.metadata import version; print(version("litellm"))' 2>&1)
if [ $? -ne 0 ]; then
    warn "Could not determine litellm version, but installation appears successful"
    LITELLM_VERSION="unknown"
fi
ok "Installed litellm $LITELLM_VERSION"

fi # end DOCKER_MODE=false guard for steps 1-3

# ---------- 4. Patch proxy config -------------------------------------------

info "Configuring proxy config for this machine..."

if [ ! -f "$CONFIG_FILE" ]; then
    fail "Proxy config not found at $CONFIG_FILE"
fi

if [ ! -f "$ROUTING_RULES" ]; then
    fail "Routing rules not found at $ROUTING_RULES"
fi

# Fix the auto_router_config_path to point to the correct path
info "Updating auto_router_config_path in proxy config..."
if [ "$DOCKER_MODE" = true ]; then
    # Inside the container, routing_rules.yaml is volume-mounted at this path
    _CONFIG_PATH="/app/litellm/router_strategy/auto_router/routing_rules.yaml"
else
    _CONFIG_PATH="$ROUTING_RULES"
fi
sedi "s|auto_router_config_path:.*|auto_router_config_path: \"$_CONFIG_PATH\"|" "$CONFIG_FILE"
if ! grep -q "auto_router_config_path: \"$_CONFIG_PATH\"" "$CONFIG_FILE"; then
    fail "Failed to update auto_router_config_path in $CONFIG_FILE

  Expected pattern not found after sed replacement.
  Manual fix required: set auto_router_config_path to $_CONFIG_PATH"
fi
ok "Updated auto_router_config_path -> $_CONFIG_PATH"

# Disable mcp_semantic_tool_filter (requires optional semantic-router package)
info "Disabling mcp_semantic_tool_filter..."
sedi "s|enabled: true|enabled: false|" "$CONFIG_FILE"
ok "Disabled mcp_semantic_tool_filter (enable after: pip install 'litellm[semantic-router]')"

# ---------- 5. API keys (.env) ----------------------------------------------
info "Setting up environment file..."
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
EOF
    if [ $? -ne 0 ]; then
        fail "Failed to create .env file at $ENV_FILE

  Check write permissions for the directory."
    fi
    ok "Created .env from environment variables"
else
    ok ".env already exists — using existing file"
fi

# ---------- 5a-docker. Docker mode: enable DB + generate master key ----------
if [ "$DOCKER_MODE" = true ]; then
    info "Enabling database-backed key management for Docker mode..."
    # Enable DB storage in proxy config
    sedi 's/store_model_in_db: false/store_model_in_db: true/' "$CONFIG_FILE"
    # Add database_url using env var reference (LiteLLM resolves os.environ/ at startup)
    if ! grep -q 'database_url:' "$CONFIG_FILE"; then
        sedi '/^general_settings:/a\  database_url: "os.environ/DATABASE_URL"' "$CONFIG_FILE"
    fi
    # Use env var reference for master_key (so Docker compose can inject it)
    sedi 's/master_key: sk-1234/master_key: os.environ\/LITELLM_MASTER_KEY/' "$CONFIG_FILE"
    # Generate master key if not already in .env
    if ! grep -q 'LITELLM_MASTER_KEY=' "$ENV_FILE"; then
        GENERATED_KEY="sk-$(openssl rand -hex 16)"
        echo "LITELLM_MASTER_KEY=$GENERATED_KEY" >> "$ENV_FILE"
        ok "Generated master key: $GENERATED_KEY (saved to .env)"
    else
        ok "Master key already set in .env"
    fi
    ok "Database and key management configured for Docker mode"
fi

# ---------- 5b. Set auto-router tier models ---------------------------------
info "Setting tier models in routing_rules.yaml..."
sedi '/^  low:/,/^  [a-z]/{s|model:.*|model: "gemini/gemini-3-flash-preview"|;}' "$ROUTING_RULES"
sedi '/^  mid:/,/^  [a-z]/{s|model:.*|model: "gemini/gemini-3-pro-preview"|;}' "$ROUTING_RULES"
sedi '/^  top:/,/^[a-z]/{s|model:.*|model: "bedrock/us.anthropic.claude-opus-4-6-v1"|;}' "$ROUTING_RULES"

# Verify tier models were set correctly
if ! grep -q 'model: "gemini/gemini-3-flash-preview"' "$ROUTING_RULES"; then
    warn "Failed to set low tier model in routing_rules.yaml"
fi
if ! grep -q 'model: "gemini/gemini-3-pro-preview"' "$ROUTING_RULES"; then
    warn "Failed to set mid tier model in routing_rules.yaml"
fi
if ! grep -q 'model: "bedrock/us.anthropic.claude-opus-4-6-v1"' "$ROUTING_RULES"; then
    warn "Failed to set top tier model in routing_rules.yaml"
fi
ok "Tier models: low=gemini-3-flash, mid=gemini-3-pro, top=opus-4-6"

# ---------- 5c. Add provider models to proxy_config.yaml --------------------
info "Preparing provider model entries..."

# Collect model entries to add, then insert them all at once before "auto".
_NEW_MODELS_FILE=$(mktemp)
if [ $? -ne 0 ] || [ -z "$_NEW_MODELS_FILE" ]; then
    fail "Failed to create temporary file for model entries

  Check that /tmp is writable and has sufficient space."
fi
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
    if [ $? -ne 0 ]; then
        warn "Failed to write model entry for $model_name to temporary file"
        return 1
    fi
    return 0
}

# Read provider models from models.yaml and queue entries for available providers
if [ ! -f "$MODELS_FILE" ]; then
    warn "models.yaml not found at $MODELS_FILE, skipping provider model registration"
    _PROVIDER_MODELS=""
else
    _PROVIDER_MODELS=$(MODELS_FILE="$MODELS_FILE" AVAILABLE="$AVAILABLE" python << 'PYEOF'
import yaml, os, sys
try:
    providers = set(os.environ.get("AVAILABLE", "").split())
    with open(os.environ["MODELS_FILE"]) as f:
        cfg = yaml.safe_load(f)
    for name, info in cfg.get("provider_models", {}).items():
        if name in providers:
            for m in info["models"]:
                print(f'{m["name"]}|{m["id"]}|{info["key_env"]}')
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)
    if [ $? -ne 0 ]; then
        warn "Failed to parse models.yaml, skipping provider model registration. Error output above."
        _PROVIDER_MODELS=""
    fi
fi

if [ -n "$_PROVIDER_MODELS" ]; then
    while IFS='|' read -r _mname _mid _mkey; do
        add_model "$_mname" "$_mid" "$_mkey"
    done <<< "$_PROVIDER_MODELS"
fi

# Flush queued models into proxy_config.yaml
if [ -s "$_NEW_MODELS_FILE" ]; then
    info "Adding queued models to proxy_config.yaml..."
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
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
        if [ $? -ne 0 ]; then
            fail "Failed to insert model entries into proxy_config.yaml using awk"
        fi
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        if [ $? -ne 0 ]; then
            fail "Failed to move temporary config file to $CONFIG_FILE"
        fi
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
        ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
        if [ $? -ne 0 ]; then
            fail "Failed to append model entries to proxy_config.yaml using awk"
        fi
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        if [ $? -ne 0 ]; then
            fail "Failed to move temporary config file to $CONFIG_FILE"
        fi
    fi
    ok "Added model(s) to proxy_config.yaml for configured providers"
else
    info "No new models to add to proxy_config.yaml"
fi
rm -f "$_NEW_MODELS_FILE"

# Ensure the "auto" model entry exists (uses the auto-router)
if ! grep -q 'model_name: auto' "$CONFIG_FILE"; then
    info "Adding auto-router entry to proxy_config.yaml..."
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
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    if [ $? -ne 0 ]; then
        fail "Failed to generate auto-router entry using awk"
    fi
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    if [ $? -ne 0 ]; then
        fail "Failed to move temporary config file to $CONFIG_FILE"
    fi
    ok "Added auto-router entry to proxy_config.yaml (default: $AUTO_DEFAULT)"
fi

# ---------- 5d. Register litellm provider with OpenClaw ---------------------

OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"

if [ -f "$OPENCLAW_CONFIG" ]; then
    info "Registering litellm provider in OpenClaw config..."
    OPENCLAW_RESULT=$(PROXY_PORT="$PROXY_PORT" python << 'PYEOF'
import json, os, sys

try:
    config_path = os.path.expanduser("~/.openclaw/openclaw.json")
    with open(config_path) as f:
        config = json.load(f)

    # Ensure models.providers path exists
    config.setdefault("models", {})
    config["models"].setdefault("providers", {})

    config["models"]["providers"]["litellm"] = {
        "baseUrl": f"http://127.0.0.1:{os.environ.get('PROXY_PORT', '4141')}/v1",
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
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)
    if [ $? -ne 0 ]; then
        warn "Failed to register litellm provider in OpenClaw config. Error: $OPENCLAW_RESULT"
    else
        ok "Added litellm provider with auto model to $OPENCLAW_CONFIG"
    fi
else
    info "OpenClaw not found (~/.openclaw/openclaw.json missing) — skipping provider registration"
fi

# ---------- 6. Start proxy ---------------------------------------------------

echo ""
echo -e "${BOLD}=== Starting LiteLLM Proxy ===${NC}"
echo ""

if [ "$DOCKER_MODE" = true ]; then
    # --- Docker mode ---
    echo -e "  Mode   : ${CYAN}Docker (PostgreSQL + Admin UI)${NC}"
    echo -e "  Config : ${CYAN}$CONFIG_FILE${NC} (volume-mounted into container)"
    echo -e "  Port   : ${CYAN}${PROXY_PORT}${NC}"
    echo ""

    # Read master key from .env for display
    _MASTER_KEY=$(grep '^LITELLM_MASTER_KEY=' "$ENV_FILE" | cut -d'=' -f2-)
    if [ -z "$_MASTER_KEY" ]; then
        _MASTER_KEY="sk-1234"
    fi

    # Build the Docker image
    info "Building Docker image (skipped if up to date)..."
    "$REPO_ROOT/build_docker_for_setup.sh"
    if [ $? -ne 0 ]; then
        fail "Docker image build failed. Check the output above."
    fi

    # Stop any existing ClawRouter containers
    info "Stopping any existing ClawRouter containers..."
    docker compose -f "$REPO_ROOT/docker-compose.clawrouter.yml" down

    # Start the stack
    info "Starting ClawRouter Docker stack..."
    CLAWROUTER_PORT="$PROXY_PORT" docker compose -f "$REPO_ROOT/docker-compose.clawrouter.yml" up -d
    if [ $? -ne 0 ]; then
        fail "Failed to start Docker containers. Check 'docker compose -f docker-compose.clawrouter.yml logs' for details."
    fi

    # Wait for health check
    info "Waiting for proxy to become healthy (up to 60s)..."
    _HEALTHY=false
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:${PROXY_PORT}/health/liveliness" > /dev/null; then
            _HEALTHY=true
            break
        fi
        sleep 2
    done

    if [ "$_HEALTHY" = false ]; then
        warn "Proxy health check timed out. It may still be starting."
        warn "Check logs: docker compose -f docker-compose.clawrouter.yml logs -f litellm"
    else
        ok "Proxy is healthy!"
    fi

    echo ""
    echo -e "${BOLD}=== ClawRouter Docker Stack Running ===${NC}"
    echo ""
    echo -e "  Proxy    : ${CYAN}http://localhost:${PROXY_PORT}${NC}"
    echo -e "  Admin UI : ${CYAN}http://localhost:${PROXY_PORT}/ui${NC}"
    echo -e "  Key      : ${CYAN}$_MASTER_KEY${NC}"
    echo ""
    echo -e "${BOLD}Create a virtual key (per-user API key):${NC}"
    echo "  curl -X POST http://localhost:${PROXY_PORT}/key/generate \\"
    echo "    -H 'Authorization: Bearer $_MASTER_KEY' \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"models\": [\"auto\"], \"max_budget\": 10}'"
    echo ""
    echo -e "${BOLD}Manage keys via UI:${NC}"
    echo "  open http://localhost:${PROXY_PORT}/ui"
    echo ""
    echo -e "${BOLD}Manage containers:${NC}"
    echo "  Stop  : docker compose -f docker-compose.clawrouter.yml down"
    echo "  Logs  : docker compose -f docker-compose.clawrouter.yml logs -f litellm"
    echo "  Rebuild: ./build_docker_for_setup.sh --force"

else
    # --- Direct mode (original behavior) ---
    echo -e "  Config : ${CYAN}$CONFIG_FILE${NC}"
    echo -e "  Port   : ${CYAN}$PROXY_PORT${NC}"
    echo -e "  Key    : ${CYAN}sk-1234${NC}  (set in config litellm_settings.master_key)"
    echo ""
    echo -e "${BOLD}Test it:${NC}"
    echo ""
    echo "  # Health check"
    echo "  curl http://localhost:$PROXY_PORT/health"
    echo ""
    echo "  # Chat completion via the auto-router"
    echo "  curl http://localhost:$PROXY_PORT/v1/chat/completions \\"
    echo '    -H "Content-Type: application/json" \'
    echo '    -H "Authorization: Bearer sk-1234" \'
    echo '    -d '"'"'{"model":"auto","messages":[{"role":"user","content":"Hello!"}]}'"'"
    echo ""
    echo -e "${GREEN}Starting...${NC}"
    echo ""

    # Load env vars
    info "Loading environment variables from $ENV_FILE..."
    set -a
    # shellcheck disable=SC1091
    source "$ENV_FILE"
    if [ $? -ne 0 ]; then
        fail "Failed to source environment file at $ENV_FILE"
    fi
    set +a

    # Kill any existing process on port $PROXY_PORT
    PORT=$PROXY_PORT
    info "Checking for existing processes on port $PORT..."
    EXISTING_PIDS=""
    if command -v lsof >/dev/null 2>&1; then
        EXISTING_PIDS=$(lsof -ti:"$PORT" 2>/dev/null)
    elif command -v fuser >/dev/null 2>&1; then
        EXISTING_PIDS=$(fuser "$PORT/tcp" 2>/dev/null | tr -s ' ' '\n')
    elif command -v ss >/dev/null 2>&1; then
        EXISTING_PIDS=$(ss -tlnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
    fi

    if [ -n "$EXISTING_PIDS" ]; then
        for pid in $EXISTING_PIDS; do
            warn "Killing process on port $PORT (PID: $pid)"
            kill "$pid"
            if [ $? -ne 0 ]; then
                warn "Failed to send TERM signal to PID $pid"
            fi
        done
        sleep 2
        # Force kill any that are still running
        for pid in $EXISTING_PIDS; do
            if kill -0 "$pid" 2>/dev/null; then
                warn "Force-killing PID $pid"
                kill -9 "$pid"
                if [ $? -ne 0 ]; then
                    warn "Failed to send KILL signal to PID $pid"
                fi
            fi
        done
        sleep 1
        ok "Port $PORT cleared"
    fi

    # Final check that litellm binary exists before exec
    LITELLM_BIN="$VENV_DIR/bin/litellm"
    if [ ! -x "$LITELLM_BIN" ]; then
        fail "LiteLLM binary not found or not executable at $LITELLM_BIN

  Expected location: $LITELLM_BIN
  Installation may have failed or the virtual environment is corrupted."
    fi

    info "Starting LiteLLM proxy server..."
    exec "$LITELLM_BIN" --config "$CONFIG_FILE" --port "$PROXY_PORT"
fi
