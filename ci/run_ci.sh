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

SIMULATOR_GUARD="$ROOT/BuildSupport/simulator_guard.sh"
# shellcheck source=BuildSupport/simulator_guard.sh
source "$SIMULATOR_GUARD"
devicehub_enter_simulator_lease device-hub-full-ci 3600 "$0" "$@"

PROCESS_GUARD="$ROOT/BuildSupport/process_guard.sh"
# shellcheck source=BuildSupport/process_guard.sh
source "$PROCESS_GUARD"
devicehub_require_guard full-ci 3600 "$0" "$@"

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
  exit "$status"
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

# Verification must not rewrite the checkout (formatting, recorded snapshots,
# regenerated artifacts). Compare against the state CI started from so local
# uncommitted work is allowed but any change made by a gate fails the run.
checkout_state() {
  {
    git status --porcelain=v1 --untracked-files=all
    git diff HEAD
  } | shasum -a 256
}
CHECKOUT_BEFORE="$(checkout_state)"

run_ci_task test
run_ci_task protocol:verify
run_ci_task lint
run_ci_task previews

CONFIGURATION=Release \
CODE_SIGNING_ALLOWED=NO \
DERIVED_DATA_PATH="$RELEASE_DERIVED_DATA_PATH" \
  run_ci_task build

if [[ "$(checkout_state)" != "$CHECKOUT_BEFORE" ]]; then
  git status --short >&2
  printf 'Verification changed the checkout.\n' >&2
  exit 1
fi

printf 'Device Hub CI passed.\n'
