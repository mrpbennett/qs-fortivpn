#!/usr/bin/env bash
# Installs the root-owned helper and a sudo rule limited to that helper.
set -euo pipefail

HELPER=/usr/local/libexec/omarchy-fortivpn-helper
CLI=/usr/local/bin/omarchy-fortivpn
SUDOERS=/etc/sudoers.d/omarchy-fortivpn

if [[ ${1:-} == --install-root ]]; then
  # pkexec sets PKEXEC_UID to the authenticated caller; it cannot be forged.
  [[ $# == 1 && ${PKEXEC_UID:-} =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' "Run this installer through pkexec as your desktop user." >&2; exit 1; }
  # getent resolves an all-digit key strictly as a UID, never as a user name.
  user=$(getent passwd "$PKEXEC_UID" | cut -d: -f1) || user=""
  [[ $user =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || { printf '%s\n' "Invalid user name." >&2; exit 1; }
  # Serialize installs system-wide: overlapping runs would back up each
  # other's files and a failed run could roll back a successful one.
  exec 9> /run/omarchy-fortivpn-install.lock
  flock -n 9 || { printf '%s\n' "Another FortiVPN setup is already running." >&2; exit 1; }
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  install -d -o root -g root -m 755 "${HELPER%/*}" "${CLI%/*}" "${SUDOERS%/*}"
  bash -n "$script_dir/omarchy-fortivpn-helper"
  bash -n "$script_dir/omarchy-fortivpn"
  "$script_dir/omarchy-fortivpn-helper" status >/dev/null

  helper_tmp=$(mktemp "$HELPER.XXXXXX")
  cli_tmp=$(mktemp "$CLI.XXXXXX")
  sudoers_tmp=$(mktemp "$SUDOERS.tmp.XXXXXX")
  helper_backup=""
  cli_backup=""
  sudoers_backup=""
  had_helper=false
  had_cli=false
  had_sudoers=false
  committed=false
  rollback() {
    if [[ $committed != true ]]; then
      if [[ $had_helper == true ]]; then mv -f "$helper_backup" "$HELPER" || true; else rm -f "$HELPER"; fi
      if [[ $had_cli == true ]]; then mv -f "$cli_backup" "$CLI" || true; else rm -f "$CLI"; fi
      if [[ $had_sudoers == true ]]; then mv -f "$sudoers_backup" "$SUDOERS" || true; else rm -f "$SUDOERS"; fi
    fi
    rm -f "$helper_tmp" "$cli_tmp" "$sudoers_tmp" "$helper_backup" "$cli_backup" "$sudoers_backup"
  }
  trap rollback EXIT
  if [[ -e $HELPER ]]; then helper_backup=$(mktemp "$HELPER.backup.XXXXXX"); cp -a -- "$HELPER" "$helper_backup"; had_helper=true; fi
  if [[ -e $CLI ]]; then cli_backup=$(mktemp "$CLI.backup.XXXXXX"); cp -a -- "$CLI" "$cli_backup"; had_cli=true; fi
  if [[ -e $SUDOERS ]]; then sudoers_backup=$(mktemp "$SUDOERS.backup.XXXXXX"); cp -a -- "$SUDOERS" "$sudoers_backup"; had_sudoers=true; fi
  install -o root -g root -m 755 "$script_dir/omarchy-fortivpn-helper" "$helper_tmp"
  install -o root -g root -m 755 "$script_dir/omarchy-fortivpn" "$cli_tmp"
  "$helper_tmp" status >/dev/null
  printf '%s ALL=(root) NOPASSWD: %s reset, %s journal *, %s status, %s stop, %s start, %s start *\n' \
    "$user" "$HELPER" "$HELPER" "$HELPER" "$HELPER" "$HELPER" "$HELPER" > "$sudoers_tmp"
  chown root:root "$sudoers_tmp"
  chmod 440 "$sudoers_tmp"
  visudo -cf "$sudoers_tmp"
  mv -f "$helper_tmp" "$HELPER"
  mv -f "$cli_tmp" "$CLI"
  mv -f "$sudoers_tmp" "$SUDOERS"
  "$HELPER" status >/dev/null
  committed=true
  printf '%s\n' "Installed and verified FortiVPN controller for $user."
  exit 0
fi

[[ $EUID != 0 ]] || { printf '%s\n' "Run this installer as your normal desktop user." >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec pkexec /usr/bin/bash "$script_dir/install-passwordless-helper.sh" --install-root
