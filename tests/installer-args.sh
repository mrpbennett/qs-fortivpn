#!/usr/bin/env bash
set -euo pipefail

# Root mode must take the target user only from pkexec's PKEXEC_UID, and must
# refuse before touching the system when it is missing, root, or overridden.
installer="$(dirname -- "$0")/../scripts/install-passwordless-helper.sh"

reject() {
  local output
  if output=$(env "$@" 2>&1); then
    printf '%s\n' "installer accepted: $*" >&2
    exit 1
  fi
  [[ $output == *"Run this installer through pkexec"* ]] || { printf '%s\n' "unexpected output: $output" >&2; exit 1; }
}

reject -u PKEXEC_UID bash "$installer" --install-root
reject PKEXEC_UID=0 bash "$installer" --install-root
reject PKEXEC_UID=abc bash "$installer" --install-root
reject PKEXEC_UID=1000 bash "$installer" --install-root someone-else
