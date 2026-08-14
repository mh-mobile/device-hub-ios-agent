#!/usr/bin/env bash

# Prepare the existing macOS login keychain for one non-interactive signing run.
# This deliberately does not change keychain lock, timeout, default, or search
# policy, and it never creates a signing keychain.
devicehub_default_signing_password_file() {
  local host_id=""
  if [[ -f "$HOME/.codex/host-id" ]]; then
    host_id="$(<"$HOME/.codex/host-id")"
  fi

  if [[ "$host_id" == "javimini" ]]; then
    printf '%s\n' "$HOME/.codex/secrets/javimini-keychain-password"
  else
    printf '%s\n' "$HOME/.codex/secrets/javi-air-keychain-password"
  fi
}

devicehub_unlock_signing_keychain() {
  local keychain_path="${1:?keychain path required}"
  local password_file="${2:?password file required}"
  local keychain_password

  if [[ "$keychain_path" != "$HOME/Library/Keychains/login.keychain-db" ]]; then
    echo "Signing helpers only use the existing login keychain: $keychain_path" >&2
    return 1
  fi

  if [[ ! -f "$keychain_path" ]]; then
    echo "Signing keychain does not exist: $keychain_path" >&2
    return 1
  fi
  if [[ ! -f "$password_file" ]]; then
    echo "Missing keychain password file: $password_file" >&2
    return 1
  fi

  keychain_password="$(<"$password_file")"
  /usr/bin/security unlock-keychain -p "$keychain_password" "$keychain_path"
  /usr/bin/security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$keychain_password" \
    "$keychain_path"
  if /usr/bin/xattr -p com.apple.quarantine "$keychain_path" >/dev/null 2>&1; then
    /usr/bin/xattr -d com.apple.quarantine "$keychain_path"
  fi
}
