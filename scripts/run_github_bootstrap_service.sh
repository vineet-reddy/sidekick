#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/github_bootstrap_service/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

export GITHUB_BOOTSTRAP_REDIRECT_BASE_URL="${GITHUB_BOOTSTRAP_REDIRECT_BASE_URL:-http://127.0.0.1:8787}"
export HOST="${HOST:-127.0.0.1}"
export PORT="${PORT:-8787}"

if [[ -z "${GITHUB_CLIENT_ID:-}" || -z "${GITHUB_CLIENT_SECRET:-}" ]]; then
  cat >&2 <<'EOF'
Missing GitHub OAuth credentials.

Set these environment variables before starting the bootstrap service:
  GITHUB_CLIENT_ID=...
  GITHUB_CLIENT_SECRET=...

Optional:
  GITHUB_BOOTSTRAP_TEMPLATE_OWNER=...
  GITHUB_BOOTSTRAP_TEMPLATE_REPO=...
  GITHUB_BOOTSTRAP_REDIRECT_BASE_URL=http://127.0.0.1:8787
EOF
  exit 1
fi

cd "$ROOT_DIR"
exec python3 -m github_bootstrap_service.bootstrap_service.server
