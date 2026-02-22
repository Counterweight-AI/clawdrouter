#!/usr/bin/env bash
# =============================================================================
# ClawRouter Docker Image Builder
#
# Builds a local Docker image from the current code state with change detection
# to avoid unnecessary rebuilds.
#
# Usage:
#   ./build_docker_for_setup.sh [--force] [--no-cache]
#
# Flags:
#   --force     Skip change detection, always rebuild
#   --no-cache  Pass --no-cache to docker build
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  fail "Failed to determine repository root directory"
fi

IMAGE_NAME="clawrouter:local"
HASH_FILE="$REPO_ROOT/.docker-build-hash"
FORCE=0
NO_CACHE=""

# --- Parse flags ---
for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    --no-cache) NO_CACHE="--no-cache" ;;
    *)          warn "Unknown flag: $arg" ;;
  esac
done

# --- Check Docker is installed and running ---
command -v docker > /dev/null || fail "Docker is not installed"
docker info > /dev/null || fail "Docker daemon is not running"

# --- Compute hash of current code state ---
if command -v sha256sum > /dev/null; then
  HASHER="sha256sum"
elif command -v shasum > /dev/null; then
  HASHER="shasum -a 256"
else
  fail "No sha256sum or shasum found"
fi

compute_hash() {
  if [ -d "$REPO_ROOT/.git" ]; then
    # Git-aware: HEAD commit + uncommitted changes + untracked files
    { git -C "$REPO_ROOT" rev-parse HEAD
      git -C "$REPO_ROOT" diff HEAD
      git -C "$REPO_ROOT" ls-files --others --exclude-standard
    } | $HASHER | cut -d' ' -f1
  else
    # Fallback: hash relevant source files
    find "$REPO_ROOT" -name '*.py' -o -name '*.yaml' -o -name '*.sh' -o -name 'Dockerfile' \
      | sort | xargs $HASHER | $HASHER | cut -d' ' -f1
  fi
}

info "Computing code state hash..."
CURRENT_HASH="$(compute_hash)"
info "Hash: ${CURRENT_HASH:0:16}..."

# --- Check if rebuild is needed ---
if [ "$FORCE" -eq 0 ]; then
  if [ -f "$HASH_FILE" ]; then
    STORED_HASH="$(cat "$HASH_FILE")"
    if [ "$STORED_HASH" = "$CURRENT_HASH" ]; then
      docker image inspect "$IMAGE_NAME" > /dev/null 2>&1
      if [ $? -eq 0 ]; then
        ok "Image ${BOLD}${IMAGE_NAME}${NC} is up to date"
        exit 0
      else
        info "Hash matches but image not found, rebuilding..."
      fi
    fi
  fi
else
  info "Force rebuild requested"
fi

# --- Build the image ---
info "Building ${BOLD}${IMAGE_NAME}${NC}..."
docker build -t "$IMAGE_NAME" $NO_CACHE -f "$REPO_ROOT/Dockerfile" "$REPO_ROOT"
if [ $? -ne 0 ]; then
  fail "Docker build failed"
fi

# --- Save hash on success ---
echo "$CURRENT_HASH" > "$HASH_FILE"
ok "Built ${BOLD}${IMAGE_NAME}${NC} successfully"
