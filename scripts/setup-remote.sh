#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/setup-remote.sh <user@host> [options]

Options:
  --branch <name>     Git branch to run on remote Pi (default: main)
  --repo <url>        Git repo URL to clone if missing (default: https://github.com/aspain/spainify.git)
  --path <dir>        Remote repo path (default: $HOME/spainify)
  --fresh             Remove generated env/config files before running setup
  --auto-stash        If remote repo is dirty, stash changes before pull and keep stash
  --discard-local     If remote repo is dirty, discard local changes before pull
  --port <port>       Local forwarded port for Spotify auth helper (default: 8888)
  --no-open           Do not auto-open browser login URL
  -h, --help          Show this help

Example:
  ./scripts/setup-remote.sh <pi-user>@<pi-ip> --fresh
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
BRANCH="main"
REPO_URL="https://github.com/aspain/spainify.git"
REMOTE_PATH=""
FRESH="0"
FORWARD_PORT="8888"
AUTO_OPEN="1"
WATCHER_PID=""
DIRTY_REPO_MODE="prompt"

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
    --auto-stash)
      DIRTY_REPO_MODE="auto-stash"
      shift
      ;;
    --discard-local)
      DIRTY_REPO_MODE="discard"
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
  echo "==> Browser auto-open enabled for Spotify login (local port ${FORWARD_PORT})."
  (
    for ((i=0; i<900; i++)); do
      if ssh -q -o BatchMode=yes -o ConnectTimeout=2 "$REMOTE_TARGET" \
        "curl -fsS --max-time 1 http://127.0.0.1:8888/healthz >/dev/null" >/dev/null 2>&1; then
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
dirty_mode_q="$(printf '%q' "$DIRTY_REPO_MODE")"
remote_script=$(cat <<'EOF_REMOTE'
set -euo pipefail

REMOTE_PATH="${REMOTE_PATH_OVERRIDE:-$HOME/spainify}"
BRANCH="${BRANCH:-main}"
REPO_URL="${REPO_URL:-https://github.com/aspain/spainify.git}"
FRESH="${FRESH:-0}"
DIRTY_REPO_MODE="${DIRTY_REPO_MODE:-prompt}"

repo_is_dirty() {
  if ! git diff --quiet --ignore-submodules --; then
    return 0
  fi
  if ! git diff --cached --quiet --ignore-submodules --; then
    return 0
  fi
  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    return 0
  fi
  return 1
}

prompt_dirty_repo_mode() {
  local choice
  while true; do
    echo >&2
    echo "Remote repo has local changes. Choose how to proceed:" >&2
    echo "  1) Auto-stash local changes and continue (recommended)" >&2
    echo "  2) Discard local changes and continue" >&2
    echo "  3) Cancel setup" >&2
    read -r -p "Choose mode: [1] " choice || true
    choice="${choice:-1}"
    if [[ "$choice" == "1" ]]; then
      echo "auto-stash"
      return 0
    fi
    if [[ "$choice" == "2" ]]; then
      echo "discard"
      return 0
    fi
    if [[ "$choice" == "3" ]]; then
      echo "cancel"
      return 0
    fi
    echo "Please enter 1, 2, or 3." >&2
  done
}

prompt_stash_post_action() {
  local choice
  while true; do
    echo >&2
    echo "Stash created. What should happen after pull/setup?" >&2
    echo "  1) Keep stash for later review (recommended)" >&2
    echo "  2) Re-apply stash now" >&2
    echo "  3) Drop stash" >&2
    read -r -p "Choose stash action: [1] " choice || true
    choice="${choice:-1}"
    if [[ "$choice" == "1" ]]; then
      echo "keep"
      return 0
    fi
    if [[ "$choice" == "2" ]]; then
      echo "reapply"
      return 0
    fi
    if [[ "$choice" == "3" ]]; then
      echo "drop"
      return 0
    fi
    echo "Please enter 1, 2, or 3." >&2
  done
}

stash_ref=""
stash_post_action="keep"

if [[ ! -d "$REMOTE_PATH/.git" ]]; then
  git clone "$REPO_URL" "$REMOTE_PATH"
fi

cd "$REMOTE_PATH"

if repo_is_dirty; then
  echo "Detected local changes in $REMOTE_PATH:"
  git status --short || true

  mode="$DIRTY_REPO_MODE"
  if [[ "$mode" == "prompt" ]]; then
    mode="$(prompt_dirty_repo_mode)"
  fi

  if [[ "$mode" == "auto-stash" ]]; then
    stash_label="setup-remote-pre-pull-$(date +%Y%m%d-%H%M%S)"
    git stash push -u -m "$stash_label" >/dev/null
    stash_ref="$(git stash list | head -n 1 | cut -d: -f1 || true)"
    echo "Stashed local changes as '$stash_label' (${stash_ref:-stash@{0}})."
    if [[ "$DIRTY_REPO_MODE" == "prompt" ]]; then
      stash_post_action="$(prompt_stash_post_action)"
    fi
  elif [[ "$mode" == "discard" ]]; then
    echo "Discarding local changes in $REMOTE_PATH."
    git reset --hard HEAD >/dev/null
    git clean -fd >/dev/null
  elif [[ "$mode" == "cancel" ]]; then
    echo "Setup cancelled."
    exit 1
  else
    echo "Unsupported DIRTY_REPO_MODE='$DIRTY_REPO_MODE'. Use prompt, auto-stash, or discard."
    exit 1
  fi
fi

git fetch origin
git switch "$BRANCH"
git pull --ff-only

if [[ -n "$stash_ref" ]]; then
  if [[ "$stash_post_action" == "keep" ]]; then
    echo "Keeping stash ${stash_ref} for later review."
  elif [[ "$stash_post_action" == "reapply" ]]; then
    echo "Re-applying ${stash_ref}."
    if ! git stash pop "$stash_ref"; then
      echo "Re-apply had conflicts; stash was kept for manual resolution."
    fi
  elif [[ "$stash_post_action" == "drop" ]]; then
    echo "Dropping ${stash_ref}."
    git stash drop "$stash_ref" >/dev/null || true
  else
    echo "Unknown stash post action '$stash_post_action'; keeping stash."
  fi
fi

if [[ "$FRESH" == "1" ]]; then
  rm -f .spainify-device.env \
    .spainify-sonos-rooms.cache \
    apps/media-actions-api/.env \
    apps/display-controller/.env \
    apps/weather-dashboard/.env \
    apps/sonify-ui/.env.local
fi

./setup.sh
EOF_REMOTE
)

remote_script_q="$(printf '%q' "$remote_script")"

echo "==> Running setup on ${REMOTE_TARGET}..."
ssh -tt -q -o LogLevel=ERROR -L "${FORWARD_PORT}:127.0.0.1:8888" "$REMOTE_TARGET" \
  "BRANCH=$branch_q REPO_URL=$repo_q FRESH=$fresh_q DIRTY_REPO_MODE=$dirty_mode_q REMOTE_PATH_OVERRIDE=$path_q bash -lc $remote_script_q"

echo "==> Finalizing setup (closing local tunnel and helper processes)..."
cleanup
WATCHER_PID=""
trap - EXIT INT TERM
echo "==> Remote setup complete."
