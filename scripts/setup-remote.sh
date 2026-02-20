#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/setup-remote.sh <user@host> [options]

Options:
  --branch <name>     Git branch to run on remote Pi (default: codex/modular-setup-refactor)
  --repo <url>        Git repo URL to clone if missing (default: https://github.com/aspain/spainify.git)
  --path <dir>        Remote repo path (default: $HOME/spainify)
  --fresh             Remove generated env/config files before running setup
  --port <port>       Local forwarded port for Spotify auth helper (default: 8888)
  --no-open           Do not auto-open browser login URL
  -h, --help          Show this help

Example:
  ./scripts/setup-remote.sh aspain@192.168.4.96 --fresh
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
}

REMOTE_TARGET=""
BRANCH="codex/modular-setup-refactor"
REPO_URL="https://github.com/aspain/spainify.git"
REMOTE_PATH=""
FRESH="0"
FORWARD_PORT="8888"
AUTO_OPEN="1"
WATCHER_PID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --path)
      REMOTE_PATH="${2:-}"
      shift 2
      ;;
    --fresh)
      FRESH="1"
      shift
      ;;
    --port)
      FORWARD_PORT="${2:-}"
      shift 2
      ;;
    --no-open)
      AUTO_OPEN="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -z "$REMOTE_TARGET" ]]; then
        REMOTE_TARGET="$1"
      else
        echo "Unexpected argument: $1"
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$REMOTE_TARGET" ]]; then
  usage
  exit 1
fi

require_cmd ssh
require_cmd curl
require_cmd git

OPEN_CMD=""
if [[ "$AUTO_OPEN" == "1" ]]; then
  if command -v open >/dev/null 2>&1; then
    OPEN_CMD="open"
  elif command -v xdg-open >/dev/null 2>&1; then
    OPEN_CMD="xdg-open"
  fi
fi

cleanup() {
  if [[ -n "$WATCHER_PID" ]] && kill -0 "$WATCHER_PID" >/dev/null 2>&1; then
    kill "$WATCHER_PID" >/dev/null 2>&1 || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ -n "$OPEN_CMD" ]]; then
  (
    for ((i=0; i<900; i++)); do
      if curl -fsS --max-time 1 "http://127.0.0.1:${FORWARD_PORT}/healthz" >/dev/null 2>&1; then
        "$OPEN_CMD" "http://127.0.0.1:${FORWARD_PORT}/login" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 1
    done
  ) &
  WATCHER_PID="$!"
fi

branch_q="$(printf '%q' "$BRANCH")"
repo_q="$(printf '%q' "$REPO_URL")"
fresh_q="$(printf '%q' "$FRESH")"
path_q="$(printf '%q' "$REMOTE_PATH")"

ssh -t -L "${FORWARD_PORT}:127.0.0.1:8888" "$REMOTE_TARGET" \
  "BRANCH=$branch_q REPO_URL=$repo_q FRESH=$fresh_q REMOTE_PATH_OVERRIDE=$path_q bash -s" <<'EOF_REMOTE'
set -euo pipefail

REMOTE_PATH="${REMOTE_PATH_OVERRIDE:-$HOME/spainify}"
BRANCH="${BRANCH:-codex/modular-setup-refactor}"
REPO_URL="${REPO_URL:-https://github.com/aspain/spainify.git}"
FRESH="${FRESH:-0}"

if [[ ! -d "$REMOTE_PATH/.git" ]]; then
  git clone "$REPO_URL" "$REMOTE_PATH"
fi

cd "$REMOTE_PATH"
git fetch origin
git switch "$BRANCH"
git pull --ff-only

if [[ "$FRESH" == "1" ]]; then
  rm -f .spainify-device.env \
    .spainify-sonos-rooms.cache \
    apps/add-current/.env \
    apps/spotify-display/.env \
    apps/weather-dashboard/.env \
    apps/sonify/.env.local
fi

./setup.sh
EOF_REMOTE
