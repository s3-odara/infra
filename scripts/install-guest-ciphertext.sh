#!/bin/sh
set -eu

directory=/var/lib/sops-nix
destination=$directory/secrets.sops.yaml
install -d -o root -g root -m 0700 "$directory"
temporary=$(mktemp "$directory/.secrets.sops.yaml.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
cat >"$temporary"
test -s "$temporary"
chown root:root "$temporary"
chmod 0600 "$temporary"
mv -f "$temporary" "$destination"
trap - EXIT HUP INT TERM
