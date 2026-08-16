#!/usr/bin/env bash
set -euo pipefail
umask 077

admin_pgp_fingerprint=B3531E573A6676E8A92060B3879D4D00108D4015
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
target=
workdir=

cleanup() {
  [[ -z $workdir ]] || rm -rf -- "$workdir"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: secrets.sh [--target <user@address>] <init|restore> <guest>

If --target is omitted, run directly on the current Incus host.
EOF
}

fail() {
  echo "secrets: $*" >&2
  exit 1
}

ensure_tools() {
  [[ ${INFRA_SECRETS_TOOLS:-} == 1 ]] && return

  local -a arguments=("$command" "$guest")
  [[ -z $target ]] || arguments=(--target "$target" "${arguments[@]}")
  exec nix shell \
    "path:$repo_root#sops" \
    "path:$repo_root#age" \
    -c env INFRA_SECRETS_TOOLS=1 "$script_dir/secrets.sh" "${arguments[@]}"
}

host_command() {
  if [[ -z $target ]]; then
    "$@"
  else
    # Callers validate names and shell-quote the only script payload.
    # shellcheck disable=SC2029
    ssh "$target" "$@"
  fi
}

install_key() {
  local key_file=$1
  local guest_script quoted_script

  guest_script=$(
    cat <<'EOF'
set -eu
directory=/var/lib/sops-nix
destination="$directory/key.txt"
install -d -o root -g root -m 0700 "$directory"
temporary=$(mktemp "$directory/.key.txt.XXXXXX")
trap 'rm -f "$temporary"' EXIT
cat >"$temporary"
test -s "$temporary"
chown root:root "$temporary"
chmod 0600 "$temporary"
ln "$temporary" "$destination" 2>/dev/null || {
  echo "age identity already exists: $destination" >&2
  exit 1
}
rm -f "$temporary"
trap - EXIT
EOF
  )

  if [[ -z $target ]]; then
    incus exec "$guest" -- sh -c "$guest_script" <"$key_file"
  else
    printf -v quoted_script "'%s'" "${guest_script//\'/\'\\\'\'}"
    ssh "$target" incus exec "$guest" -- sh -c "$quoted_script" <"$key_file"
  fi
}

init_guest() {
  local namespace=$1
  local identity recipient recipient_file encrypted_identity

  mkdir -p "${namespace%/*}"
  mkdir "$namespace" 2>/dev/null ||
    fail "secret namespace already exists: $namespace"
  workdir=$(mktemp -d)
  identity="$workdir/identity.age"
  age-keygen -o "$identity"
  recipient=$(age-keygen -y "$identity")

  encrypted_identity="$namespace/identity.sops.json"
  recipient_file="$namespace/recipient.txt"
  if ! sops --config /dev/null encrypt \
    --pgp "$admin_pgp_fingerprint" \
    --input-type binary \
    --output-type json \
    --output "$encrypted_identity" \
    "$identity"; then
    rm -rf -- "$namespace"
    fail "failed to encrypt the age identity"
  fi

  printf '%s\n' "$recipient" >"$recipient_file"
  chmod 0644 "$recipient_file"
  "$script_dir/regenerate-sops.sh"

  if ! install_key "$identity"; then
    echo "secrets: identity was archived but not installed; retry with restore" >&2
    return 1
  fi

  echo "Initialized the age identity for $host/$guest"
  echo "Age recipient: $recipient"
  echo "Updated .sops.yaml"
  echo "Next, edit secrets/guests/$host/$guest/secrets.sops.yaml with sops"
}

restore_guest() {
  local namespace=$1
  local encrypted_identity="$namespace/identity.sops.json"
  local identity

  [[ -f $encrypted_identity ]] ||
    fail "encrypted identity not found: $encrypted_identity"
  workdir=$(mktemp -d)
  identity="$workdir/identity.age"
  sops decrypt \
    --input-type json \
    --output-type binary \
    --output "$identity" \
    "$encrypted_identity"
  chmod 0600 "$identity"
  install_key "$identity"
  echo "Restored the age identity for $host/$guest"
}

main() {
  if [[ ${1:-} == --target ]]; then
    (($# >= 2)) || fail "--target requires user@address"
    target=$2
    [[ $target == *@* && $target != -* ]] ||
      fail "target must have the form user@address"
    shift 2
  fi

  (($# == 2)) || {
    usage >&2
    exit 1
  }
  command=$1
  guest=$2
  case $command in init | restore) ;; *) fail "unknown command: $command" ;; esac
  if [[ ! $guest =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    ((${#guest} > 63)); then
    fail "invalid guest name: $guest"
  fi

  ensure_tools
  host=$(host_command uname -n) || fail "cannot determine the Incus host name"
  host=${host%%.*}
  if [[ ! $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    ((${#host} > 63)); then
    fail "invalid Incus host name: $host"
  fi
  host_command incus info "$guest" >/dev/null || fail "Incus guest not found: $guest"

  namespace="$repo_root/secrets/guests/$host/$guest"
  case $command in
  init) init_guest "$namespace" ;;
  restore) restore_guest "$namespace" ;;
  esac
}

main "$@"
