#!/usr/bin/env bash
set -euo pipefail
umask 077

guest=tuwunel
service=matrix-invite-bot.service
binary=/run/current-system/sw/bin/matrix-invite-bot
environment_file=/run/secrets/rendered/matrix-invite-bot.env
lock_directory=/run/matrix-invite-bot-bootstrap.lock
lock_held=0
service_was_active=0

# shellcheck disable=SC2329 # Called by the EXIT trap.
cleanup() {
  status=$?
  trap - EXIT
  set +e
  unset bot_password

  restore_status=0
  if ((service_was_active)); then
    incus exec "$guest" -- systemctl start "$service" || restore_status=$?
    if ((restore_status == 0)); then
      incus exec "$guest" -- systemctl is-active --quiet "$service" || restore_status=$?
    fi
    if ((restore_status != 0)); then
      printf 'Failed to restore active state for %s.\n' "$service" >&2
    fi
  fi

  lock_status=0
  if ((lock_held)); then
    incus exec "$guest" -- rmdir -- "$lock_directory" || lock_status=$?
    if ((lock_status != 0)); then
      printf 'Failed to remove guest bootstrap lock %s.\n' "$lock_directory" >&2
    fi
  fi

  if ((status == 0 && restore_status != 0)); then
    status=$restore_status
  elif ((status == 0 && lock_status != 0)); then
    status=$lock_status
  fi

  if ((status == 0)); then
    if ((service_was_active)); then
      printf 'Cross-signing bootstrap succeeded; %s was restored active.\n' "$service"
    else
      printf 'Cross-signing bootstrap succeeded; %s remains intentionally inactive.\n' "$service"
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

incus exec "$guest" -- test -x "$binary"
if incus exec "$guest" -- mkdir -- "$lock_directory"; then
  lock_held=1
else
  printf 'Another invite-bot bootstrap helper holds %s; refusing concurrent store access.\n' "$lock_directory" >&2
  exit 1
fi
printf 'This lock coordinates only this helper; do not run Restic or manual invite-bot store operations concurrently.\n' >&2

if incus exec "$guest" -- systemctl is-active --quiet "$service"; then
  service_was_active=1
  incus exec "$guest" -- systemctl stop "$service"
fi

printf 'Bot password: ' > /dev/tty
IFS= read -r -s bot_password < /dev/tty
printf '\n' > /dev/tty
if [[ -z "$bot_password" ]]; then
  unset bot_password
  printf 'Bot password must not be empty.\n' >&2
  exit 1
fi

status=0
# shellcheck disable=SC2016 # The single-quoted program expands only inside the guest.
printf '%s\n' "$bot_password" | incus exec -T "$guest" -- /bin/sh -ceu '
  environment_file=$1
  binary=$2
  test -r "$environment_file"
  test -x "$binary"

  set -a
  . "$environment_file"
  STATE_DIRECTORY=/var/lib/matrix-invite-bot
  export STATE_DIRECTORY
  set +a

  runuser=$(readlink -f /run/current-system/sw/bin/runuser)
  case "$runuser" in
    /nix/store/*/bin/runuser) ;;
    *) echo "runuser did not resolve to an immutable Nix store path" >&2; exit 1 ;;
  esac
  exec "$runuser" --user matrix-invite-bot --preserve-environment -- \
    "$binary" bootstrap-cross-signing
' bootstrap-cross-signing "$environment_file" "$binary" || status=$?
unset bot_password
exit "$status"
