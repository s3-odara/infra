#!/usr/bin/env bash
set -euo pipefail
umask 077

admin_pgp_fingerprint=B3531E573A6676E8A92060B3879D4D00108D4015
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
target=
workdir=
remote_key=

cleanup() {
  [[ -z $workdir ]] || rm -rf -- "$workdir"
  if [[ -n $remote_key && -n $target ]]; then
    # remote_key is generated remotely and validated before assignment.
    # shellcheck disable=SC2029
    ssh "$target" "rm -f -- '$remote_key'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: secrets.sh [--target <user@address>] <init|restore> <guest|host>

The name "host" is reserved for the Incus host itself.
If --target is omitted, run directly on the current Incus host.
EOF
}

fail() {
  echo "secrets: $*" >&2
  exit 1
}

ensure_tools() {
  [[ ${INFRA_SECRETS_TOOLS:-} == 1 ]] && return

  local -a arguments=("$command" "$subject")
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
    # Callers only pass fixed commands and validated names.
    # shellcheck disable=SC2029
    ssh "$target" "$@"
  fi
}

install_key() {
  local key_file=$1
  local install_script quoted_script

  install_script=$(
    cat <<'EOF'
set -eu
directory=/var/lib/sops-nix
destination="$directory/key.txt"
install -d -o root -g root -m 0700 "$directory"
temporary=$(mktemp "$directory/.key.txt.XXXXXX")
trap 'rm -f "$temporary"' EXIT
if [ "$#" -eq 0 ]; then
  cat >"$temporary"
else
  cat "$1" >"$temporary"
fi
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

  if [[ $subject == host ]]; then
    if [[ -z $target ]]; then
      doas sh -c "$install_script" <"$key_file"
    else
      remote_key=$(ssh "$target" 'umask 077; mktemp /tmp/infra-age-key.XXXXXXXX')
      [[ $remote_key =~ ^/tmp/infra-age-key\.[A-Za-z0-9]+$ ]] ||
        fail "invalid remote temporary path"
      # remote_key is generated remotely and restricted by the check above.
      # shellcheck disable=SC2029
      ssh "$target" "cat >'$remote_key'" <"$key_file"
      printf -v quoted_script "'%s'" "${install_script//\'/\'\\\'\'}"
      ssh -t "$target" doas sh -c "$quoted_script" sh "$remote_key"
      # shellcheck disable=SC2029
      ssh "$target" "rm -f -- '$remote_key'"
      remote_key=
    fi
  elif [[ -z $target ]]; then
    incus exec "$subject" -- sh -c "$install_script" <"$key_file"
  else
    printf -v quoted_script "'%s'" "${install_script//\'/\'\\\'\'}"
    ssh "$target" incus exec "$subject" -- sh -c "$quoted_script" <"$key_file"
  fi
}

init_identity() {
  local identity recipient

  mkdir -p "${namespace%/*}"
  mkdir "$namespace" 2>/dev/null ||
    fail "secret namespace already exists: $namespace"
  workdir=$(mktemp -d)
  identity="$workdir/identity.age"
  age-keygen -o "$identity"
  recipient=$(age-keygen -y "$identity")

  if ! sops --config /dev/null encrypt \
    --pgp "$admin_pgp_fingerprint" \
    --input-type binary \
    --output-type json \
    --output "$namespace/identity.sops.json" \
    "$identity"; then
    rm -rf -- "$namespace"
    fail "failed to encrypt the age identity"
  fi

  printf '%s\n' "$recipient" >"$namespace/recipient.txt"
  chmod 0644 "$namespace/recipient.txt"
  "$script_dir/regenerate-sops.sh"

  if ! install_key "$identity"; then
    echo "secrets: identity was archived but not installed; retry with restore" >&2
    return 1
  fi

  echo "Initialized the age identity for $name"
  echo "Age recipient: $recipient"
  echo "Updated .sops.yaml"
  echo "Next, edit $secret_file with sops"
}

restore_identity() {
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
  echo "Restored the age identity for $name"
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
  subject=$2
  case $command in init | restore) ;; *) fail "unknown command: $command" ;; esac
  if [[ ! $subject =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    ((${#subject} > 63)); then
    fail "invalid guest name: $subject"
  fi

  ensure_tools
  host=$(host_command uname -n) || fail "cannot determine the Incus host name"
  host=${host%%.*}
  if [[ ! $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    ((${#host} > 63)); then
    fail "invalid Incus host name: $host"
  fi

  if [[ $subject == host ]]; then
    namespace="$repo_root/secrets/hosts/$host"
    name=$host
  else
    host_command incus info "$subject" >/dev/null ||
      fail "Incus guest not found: $subject"
    namespace="$repo_root/secrets/guests/$host/$subject"
    name="$host/$subject"
  fi
  secret_file="${namespace#"$repo_root"/}/secrets.sops.yaml"

  case $command in
  init) init_identity ;;
  restore) restore_identity ;;
  esac
}

main "$@"
