set positional-arguments

repo_root := justfile_directory()

# Show help. Run `just help manage-secrets` for secret management usage
help topic="":
    #!/usr/bin/env bash
    set -euo pipefail

    case "$1" in
      "")
        cat <<'EOF'
    infra tasks

    Usage:
      just <command> [arguments]

    Commands:
      check                   Validate the configuration statically
      install-host            Install a NixOS host
      deploy-guests           Deploy Incus resources and guest configurations
      manage-secrets          Manage host and guest secrets

      apply-tofu              Apply only the OpenTofu configuration
      upgrade-guests          Upgrade guest configurations
      upgrade-host            Upgrade the host configuration
      regenerate-sops         Regenerate .sops.yaml
      update-eturnal          Update eturnal and its locked dependencies
      update-matrix-invite-bot Update Matrix invite bot dependencies
      update-sygnal           Update Sygnal
      update-web-clients      Update Sable
      update-flake            Update flake inputs and generated files

    Examples:
      just install-host mecha-vultr root@HOST
      just deploy-guests
      just manage-secrets init prosody
      just manage-secrets init host

    Run `just help manage-secrets` for secret management usage.
    EOF
        ;;
      manage-secrets)
        cat <<'EOF'
    Usage:
      just manage-secrets [--target USER@HOST] <init|restore> <GUEST|host>

    The name "host" is reserved for host secrets.

    Examples:
      just manage-secrets init prosody
      just manage-secrets init host
    EOF
        ;;
      *)
        printf 'Unknown help topic: %s\n' "$1" >&2
        printf 'Available topics: manage-secrets\n' >&2
        exit 1
        ;;
    esac

check: _check-nix _check-tofu _check-shell

_check-nix:
    nix flake check --no-build "path:{{ repo_root }}"
    nix eval --json "path:{{ repo_root }}#nixosConfigurations" --apply 'configs: builtins.mapAttrs (_: cfg: cfg.config.system.build.toplevel.drvPath) configs' >/dev/null
    git ls-files -z -- '*.nix' | xargs -0 -r nix fmt -- --check

_check-tofu:
    nix shell "path:{{ repo_root }}#opentofu" -c sh -eu -c '\
      tofu=$(command -v tofu); \
      "$tofu" -chdir=tofu fmt -check -recursive; \
      doas "$tofu" -chdir=tofu init -backend=false -lockfile=readonly; \
      "$tofu" -chdir=tofu validate; \
      for var_file in tofu/hosts/*.tfvars; do \
        "$tofu" -chdir=tofu test -var-file="${var_file#tofu/}"; \
      done'

_check-shell:
    find scripts modules -type f -name '*.sh' -print0 | xargs -0 -r bash -n
    find scripts modules -type f -name '*.sh' -print0 | xargs -0 -r nix shell "path:{{ repo_root }}#shfmt" -c shfmt -d -i 2

deploy-guests: apply-tofu
    ./scripts/guests.sh

apply-tofu:
    doas /run/current-system/sw/bin/tofu -chdir=tofu init
    doas /run/current-system/sw/bin/tofu -chdir=tofu apply -var-file="hosts/$(hostname -s).tfvars"

upgrade-guests *guests:
    ./scripts/guests.sh "$@"

upgrade-host:
    doas nixos-rebuild boot --flake "path:{{ repo_root }}#$(hostname -s)"

manage-secrets *args:
    ./scripts/secrets.sh "$@"

# 全recipient.txtから.sops.yamlを再生成する
regenerate-sops:
    ./scripts/regenerate-sops.sh

install-host configuration target:
    ./scripts/install-host.sh "$@"

# eturnal本体と固定したErlang依存を更新する
update-eturnal:
    nix shell "path:{{ repo_root }}#curl" "path:{{ repo_root }}#jq" -c ./scripts/update-eturnal.sh

# Matrix invite botのRust依存を更新する
update-matrix-invite-bot:
    nix shell --inputs-from "path:{{ repo_root }}" nixpkgs#cargo -c cargo update --manifest-path packages/matrix-invite-bot/Cargo.toml
    nix build --no-link "path:{{ repo_root }}#matrix-invite-bot"

# Sygnal本体のreleaseとsource hashを更新する
update-sygnal:
    nix shell "path:{{ repo_root }}#curl" "path:{{ repo_root }}#jq" -c ./scripts/update-sygnal.sh

# Sable OCI pinを更新する。HTML patch/SHA gateは表示される手順で手動更新する
update-web-clients:
    nix shell \
      "path:{{ repo_root }}#curl" \
      "path:{{ repo_root }}#jq" \
      "path:{{ repo_root }}#nix-prefetch-docker" \
      -c ./scripts/update-web-clients.sh

# flake.lockとkernel configを更新する
update-flake:
    ./scripts/update-flake.sh
    just _check-nix
