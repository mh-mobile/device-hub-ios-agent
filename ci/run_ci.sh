#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${CI:-}" && "${DEVICE_HUB_FULL_CI:-0}" != "1" ]]; then
  CI_SCOPE="$(python3 BuildSupport/ci_scope.py --repository "$ROOT")"
  if [[ "$CI_SCOPE" == "documentation" ]]; then
    git diff --check
    printf 'Device Hub documentation checks passed. Set DEVICE_HUB_FULL_CI=1 to run every gate.\n'
    exit 0
  fi
fi

# Acquire the shared simulator before the process guard. The simulator
# supervisor re-executes this script and cannot preserve the guard's private
# file descriptor across that boundary.
if [[ -z "${CODEX_SIMULATOR_LEASE_ID:-}" ]] \
  && command -v codex-simulator-lease >/dev/null 2>&1; then
  exec "$(command -v codex-simulator-lease)" run \
    --name device-hub-full-ci \
    --timeout-seconds 3600 \
    -- "$0" "$@"
fi

PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard full-ci 3600 "$0" "$@"

SIMULATOR_GUARD="$ROOT/BuildSupport/simulator_guard.sh"
# shellcheck source=BuildSupport/simulator_guard.sh
source "$SIMULATOR_GUARD"
devicehub_require_simulator device-hub-full-ci 3600 "$0" "$@"

RELEASE_DERIVED_DATA_PATH=""
cleanup() {
  local status=$?
  if [[ -n "$RELEASE_DERIVED_DATA_PATH" ]]; then
    rm -rf "$RELEASE_DERIVED_DATA_PATH"
  fi
  if ! devicehub_cleanup_simulator; then
    status=125
  fi
  return "$status"
}
trap cleanup EXIT

RELEASE_DERIVED_DATA_PATH="$(
  mktemp -d "${TMPDIR:-/private/tmp}/device-hub-release.XXXXXX"
)"

# mise closes inherited file descriptors before it starts a task. Keep the
# outer full-CI guard, but make each nested guarded task acquire a separate
# lock instead of trusting the descriptor that mise cannot preserve.
NESTED_GUARD_LOCK_PATH="${TMPDIR:-/private/tmp}/device-hub-ios-full-ci-nested.$$.lock"
run_ci_task() {
  DEVICE_HUB_GUARD_HELD=0 \
    DEVICE_HUB_GUARD_FD='' \
    DEVICE_HUB_GUARD_LOCK_PATH="$NESTED_GUARD_LOCK_PATH" \
    mise run "$@"
}

run_ci_task test
run_ci_task protocol:verify
run_ci_task lint
run_ci_task previews

CONFIGURATION=Release \
CODE_SIGNING_ALLOWED=NO \
DERIVED_DATA_PATH="$RELEASE_DERIVED_DATA_PATH" \
  run_ci_task build

printf 'Device Hub CI passed.\n'
