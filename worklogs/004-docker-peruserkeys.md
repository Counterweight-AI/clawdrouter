# 004 — Docker Proxy with Per-User API Keys

## Goal
Enable per-user API key management in ClawRouter by running the full LiteLLM proxy stack (proxy + PostgreSQL + Admin UI) via Docker, using our custom ClawRouter source code — not the upstream prebuilt image.

---

## Context & Motivation

- The bare `./setup.sh` launches `litellm` directly; no database → no virtual key support.
- LiteLLM already has full virtual key management (Admin UI at `/ui`, `POST /key/generate`, per-user budgets/spend tracking) — but it **requires PostgreSQL**.
- The repo already contained a `Dockerfile` (multi-stage Chainguard wolfi-base, builds Admin UI, generates Prisma client, exposes port 4000) and a `docker-compose.yml` (PostgreSQL 16 + upstream `litellm:main-stable` image).
- Goal: wire everything together so `./setup.sh --docker` handles the full lifecycle.

---

## What Was Built

### 1. `build_docker_for_setup.sh` (new)
- Builds `clawrouter:local` from the existing `Dockerfile` (no Dockerfile changes needed).
- **Change detection:** hashes `git rev-parse HEAD + git diff HEAD + untracked files`; skips rebuild if hash matches `.docker-build-hash` and image exists.
- Supports `--force` (always rebuild) and `--no-cache` flags.
- Uses same `info`/`ok`/`warn`/`fail` colour helper style as `setup.sh`.
- `.docker-build-hash` added to `.gitignore` (local state only).

### 2. `docker-compose.clawrouter.yml` (new)
- Kept **separate** from upstream `docker-compose.yml` to avoid future merge conflicts.
- `litellm` service: `image: clawrouter:local` (no `build:` key), ports `${CLAWROUTER_PORT:-4141}:4000`.
- **Volume mounts (read-only):**
  - `./litellm/proxy/proxy_config.yaml → /app/config.yaml`
  - `./litellm/router_strategy/auto_router/routing_rules.yaml → /app/litellm/router_strategy/auto_router/routing_rules.yaml`
- Passes `DATABASE_URL`, `STORE_MODEL_IN_DB=True`, `LITELLM_MASTER_KEY` as environment; `env_file: .env` passes API keys.
- `db` service: `postgres:16`, container name `clawrouter_db`, named volume `clawrouter_postgres_data`, full healthcheck.
- `depends_on: db` with `condition: service_healthy` — prevents startup race.
- No prometheus (kept simple).

### 3. `setup.sh` — `--docker` flag (modified, ~184 lines added)

**Flag parsing:** added immediately after variable declarations:
```bash
DOCKER_MODE=false
for arg in "$@"; do case "$arg" in --docker) DOCKER_MODE=true ;; esac; done
```

**Steps skipped in Docker mode:** Python check, venv creation, pip install (steps 1–3 wrapped in `if [ "$DOCKER_MODE" = false ]`).

**Key path insight:** `auto_router_config_path` in `proxy_config.yaml` must point to the *container-internal* path when running in Docker (`/app/litellm/router_strategy/auto_router/routing_rules.yaml`), not the host absolute path. Step 4 now conditionally sets `_CONFIG_PATH` based on `DOCKER_MODE`.

**Database enablement (step 5a-docker):**
- `store_model_in_db: false → true` (via sed)
- Appends `database_url: "os.environ/DATABASE_URL"` under `general_settings:` if absent
- Replaces `master_key: sk-1234` → `master_key: os.environ/LITELLM_MASTER_KEY`
- Generates `LITELLM_MASTER_KEY=sk-<16-byte-hex>` via `openssl rand -hex 16`, appends to `.env`

**Launch (step 6 Docker branch):**
1. `./build_docker_for_setup.sh` (smart rebuild)
2. `docker compose -f docker-compose.clawrouter.yml down` (idempotent stop)
3. `docker compose -f docker-compose.clawrouter.yml up -d`
4. Poll `/health/liveliness` for up to 60s
5. Print: proxy URL, Admin UI URL, master key, `POST /key/generate` example, stop/log/rebuild commands

**Direct mode (no flag):** 100% unchanged — same Python/venv/exec flow as before.

### 4. `.gitignore` + `CLAUDE.md`
- `.docker-build-hash` added to `.gitignore`.
- `CLAUDE.md` Quick Start updated; new "Docker Mode (Per-User API Keys)" section added with UI access, API key generation, and container management commands.

---

## Architecture: How Per-User Keys Work

```
User sends request with virtual key (sk-abc...)
  → LiteLLM proxy validates key against PostgreSQL
  → If valid: route request via auto-router (low/mid/top tier)
  → Track spend against user's budget in PostgreSQL
  → Return response with tier prefix ([low]/[med]/[high])
```

- **Admin UI** (`/ui`): create users, generate keys, set budgets, view spend — no API calls needed.
- **Master key** (in `.env`): admin credential for key management API and UI.
- **Virtual keys**: per-user keys with optional model restrictions and budget caps.

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Separate `docker-compose.clawrouter.yml` | Avoids merge conflicts with upstream `docker-compose.yml` |
| No `build:` in compose — separate build script | Enables smart change detection; compose doesn't support it |
| Volume-mount configs (read-only) | Config changes on host take effect after container restart, no image rebuild needed |
| Container path for `auto_router_config_path` | Host absolute path doesn't exist inside container |
| `os.environ/DATABASE_URL` in proxy config | LiteLLM resolves `os.environ/` at startup; avoids hardcoding DB creds in config file |
| Master key via `.env` + `os.environ/` | Key persists across restarts; not baked into image or config |
| Direct mode unchanged | Zero regression risk; Docker is purely opt-in |

---

## Commits (branch: `feat/setupsh-builds`)

| Hash | Message |
|------|---------|
| `9faefc9` | feat: add build_docker_for_setup.sh for smart Docker image building |
| `9f916ed` | feat: add docker-compose.clawrouter.yml for per-user API key support |
| `b716398` | feat: add --docker mode to setup.sh for per-user API key support |
| `c96f09d` | docs: update .gitignore and CLAUDE.md for Docker mode |

---

## Verification Steps (for replication)

```bash
# Ensure env vars are set first
export GOOGLE_API_KEY=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_REGION_NAME=...

# Run Docker mode setup
./setup.sh --docker

# Verify proxy
curl http://localhost:4141/health

# Access Admin UI
open http://localhost:4141/ui

# Generate a virtual key (use LITELLM_MASTER_KEY from .env)
curl -X POST http://localhost:4141/key/generate \
  -H "Authorization: Bearer <master-key>" \
  -H "Content-Type: application/json" \
  -d '{"models": ["auto"], "max_budget": 10}'

# Use virtual key for auto-routed request
curl http://localhost:4141/v1/chat/completions \
  -H "Authorization: Bearer <virtual-key>" \
  -H "Content-Type: application/json" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "Hello"}]}'
# Response should be prefixed: "[low] ..."
```

---

## Known Gaps / Future Work

- **Prisma migration on first run:** LiteLLM handles this internally via subprocess on startup; no explicit migration step needed — but worth monitoring on first deployment.
- **Hot config reload:** routing_rules.yaml changes require `docker compose restart litellm`; no hot-reload mechanism yet.
- **OpenClaw registration in Docker mode:** Currently skipped (step 5d runs after .env but before Docker launch — could be wired to use Docker port/master key).
- **HTTPS/TLS:** Not configured; suitable for local/internal use only as-is.
- **Postgres password hardening:** Default `dbpassword9090` is fine for local dev; production deployments should set `POSTGRES_PASSWORD` env var.
