#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
DEVICE_CONFIG_FILE="$ROOT_DIR/.spainify-device.env"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib/device_config.sh"

failures=0
warnings=0

pass() {
  echo "PASS: $1"
}

warn() {
  echo "WARN: $1"
  warnings=$((warnings + 1))
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

require_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "found command '$cmd'"
  else
    fail "missing required command '$cmd'"
  fi
}

normalize_service_flags() {
  local key
  for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
    printf -v "$key" '%s' "$(spainify_normalize_bool "${!key:-}" "$(spainify_service_default "$key")")"
  done
}

check_enabled_service() {
  local key="$1"
  local unit
  local active
  local enabled

  if [[ "${!key:-0}" != "1" ]]; then
    return
  fi

  unit="$(spainify_service_unit "$key")"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"

  if [[ "$active" == "active" ]]; then
    pass "$unit is active"
  else
    fail "$unit is not active (got '$active')"
  fi

  if [[ "$enabled" == "enabled" ]]; then
    pass "$unit is enabled"
  else
    fail "$unit is not enabled (got '$enabled')"
  fi
}

check_legacy_unit_absent() {
  local unit="$1"
  if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^${unit}[[:space:]]"; then
    fail "legacy unit file still present: $unit"
  else
    pass "legacy unit file absent: $unit"
  fi
}

check_dir_exists() {
  local dir="$1"
  if [[ -d "$ROOT_DIR/$dir" ]]; then
    pass "directory exists: $dir"
  else
    fail "missing directory: $dir"
  fi
}

echo "== Spainify Healthcheck =="
echo "Repo: $ROOT_DIR"
echo

require_cmd systemctl
require_cmd curl

if [[ -f "$DEVICE_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEVICE_CONFIG_FILE"
  pass "loaded device config: $DEVICE_CONFIG_FILE"
else
  warn "device config missing ($DEVICE_CONFIG_FILE); using defaults"
fi

normalize_service_flags
spainify_apply_service_dependencies >/dev/null || true

echo
echo "== Service State =="
for key in "${SPAINIFY_SERVICE_KEYS[@]}"; do
  check_enabled_service "$key"
done

echo
echo "== Legacy Units =="
check_legacy_unit_absent "add-current.service"
check_legacy_unit_absent "spotify_display.service"
check_legacy_unit_absent "sonify-serve.service"

echo
echo "== Directory Layout =="
check_dir_exists "apps/media-actions-api"
check_dir_exists "apps/display-controller"
check_dir_exists "apps/sonify-ui"
check_dir_exists "apps/sonos-http-api"
check_dir_exists "apps/weather-dashboard"

echo
echo "== Config Keys =="
if [[ -f "$DEVICE_CONFIG_FILE" ]]; then
  if grep -Eq '^(ENABLE_ADD_CURRENT|ENABLE_SPOTIFY_DISPLAY|ENABLE_SONIFY_SERVE)=' "$DEVICE_CONFIG_FILE"; then
    fail "legacy service keys detected in $DEVICE_CONFIG_FILE"
  else
    pass "device config uses renamed service keys"
  fi
fi

if [[ -f "$ROOT_DIR/apps/sonify-ui/.env.local" ]]; then
  if grep -Eq '^VUE_APP_MEDIA_ACTIONS_BASE=' "$ROOT_DIR/apps/sonify-ui/.env.local"; then
    pass "sonify-ui metadata key present (VUE_APP_MEDIA_ACTIONS_BASE)"
  else
    warn "VUE_APP_MEDIA_ACTIONS_BASE missing in apps/sonify-ui/.env.local"
  fi
  if grep -Eq '^VUE_APP_ADD_CURRENT_BASE=' "$ROOT_DIR/apps/sonify-ui/.env.local"; then
    fail "legacy metadata key still present (VUE_APP_ADD_CURRENT_BASE)"
  else
    pass "legacy metadata key absent (VUE_APP_ADD_CURRENT_BASE)"
  fi
else
  warn "apps/sonify-ui/.env.local missing"
fi

if [[ "${ENABLE_MEDIA_ACTIONS_API:-0}" == "1" ]]; then
  echo
  echo "== API Checks =="
  health_payload="$(curl -fsS --max-time 5 http://127.0.0.1:3030/health || true)"
  if [[ "$health_payload" == *'"ok":true'* ]]; then
    pass "media-actions-api health endpoint responded with ok=true"
  else
    fail "media-actions-api health endpoint did not return ok=true"
  fi

  if curl -fsS --max-time 5 http://127.0.0.1:3030/media-actions-smart >/dev/null; then
    pass "media-actions-smart endpoint responded successfully"
  else
    fail "media-actions-smart endpoint check failed"
  fi
fi

echo
if (( failures > 0 )); then
  echo "Healthcheck completed with $failures failure(s) and $warnings warning(s)."
  exit 1
fi

echo "Healthcheck passed with $warnings warning(s)."
