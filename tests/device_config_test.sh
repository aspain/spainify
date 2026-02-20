#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/device_config.sh"

failures=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $label (expected '$expected', got '$actual')"
    failures=$((failures + 1))
  fi
}

test_normalize_bool() {
  assert_eq "1" "$(spainify_normalize_bool "yes" "0")" "normalize yes"
  assert_eq "0" "$(spainify_normalize_bool "no" "1")" "normalize no"
  assert_eq "1" "$(spainify_normalize_bool "" "1")" "normalize empty default"
  assert_eq "0" "$(spainify_normalize_bool "garbage" "0")" "normalize garbage default"
}

test_read_env_value() {
  local f
  f="$(mktemp)"
  cat >"$f" <<'EOF_ENV'
FOO=bar
QUOTED="hello world"
SINGLE='single value'
EOF_ENV

  assert_eq "bar" "$(spainify_read_env_value "$f" "FOO")" "read plain env"
  assert_eq "hello world" "$(spainify_read_env_value "$f" "QUOTED")" "read quoted env"
  assert_eq "single value" "$(spainify_read_env_value "$f" "SINGLE")" "read single-quoted env"

  rm -f "$f"
}

test_dependencies() {
  ENABLE_ADD_CURRENT=0
  ENABLE_SPOTIFY_DISPLAY=1
  ENABLE_WEATHER_DASHBOARD=0
  ENABLE_SONOS_HTTP_API=0
  ENABLE_SONIFY_SERVE=0
  spainify_apply_service_dependencies >/dev/null

  assert_eq "1" "$ENABLE_SONIFY_SERVE" "display implies sonify"
  assert_eq "1" "$ENABLE_SONOS_HTTP_API" "display implies sonos api"

  ENABLE_ADD_CURRENT=0
  ENABLE_SPOTIFY_DISPLAY=0
  ENABLE_WEATHER_DASHBOARD=0
  ENABLE_SONOS_HTTP_API=0
  ENABLE_SONIFY_SERVE=1
  spainify_apply_service_dependencies >/dev/null

  assert_eq "1" "$ENABLE_SONOS_HTTP_API" "sonify implies sonos api"
}

test_room_parse() {
  local f
  local rooms
  f="$(mktemp)"
  cat >"$f" <<'EOF_JSON'
[
  {
    "members": [
      {"roomName": "Living Room"},
      {"roomName": "Kitchen"}
    ]
  },
  {
    "members": [
      {"roomName": "Move"},
      {"roomName": "Kitchen"}
    ]
  }
]
EOF_JSON

  rooms="$(spainify_parse_rooms_from_zones_json "$f")"
  rm -f "$f"

  assert_eq $'Kitchen\nLiving Room\nMove' "$rooms" "room parsing and sort"
}

test_normalize_bool
test_read_env_value
test_dependencies
test_room_parse

if (( failures > 0 )); then
  echo
  echo "$failures test(s) failed."
  exit 1
fi

echo "All tests passed."
