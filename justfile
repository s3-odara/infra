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
      manage-secrets          Manage guest secrets

      apply-tofu              Apply only the OpenTofu configuration
      upgrade-guests          Upgrade guest configurations
      upgrade-host            Upgrade the host configuration
      regenerate-sops         Regenerate .sops.yaml
      update-flake            Update flake inputs and generated files

    Examples:
      just install-host incus-01 root@HOST
      just deploy-guests
      just manage-secrets init prosody

    Run `just help manage-secrets` for secret management usage.
    EOF
        ;;
      manage-secrets)
        cat <<'EOF'
    Usage:
      just manage-secrets [--target USER@HOST] <init|restore> GUEST

    Commands:
      init      Create an age identity
      restore   Restore an age identity to a guest

    Examples:
      just manage-secrets init prosody
      just manage-secrets --target me@HOST restore prosody
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
    bash -n scripts/*.sh
    nix shell "path:{{ repo_root }}#shfmt" -c shfmt -d -i 2 scripts/*.sh

deploy-guests: apply-tofu
    ./scripts/guests.sh

apply-tofu:
    doas /run/current-system/sw/bin/tofu -chdir=tofu init
    doas /run/current-system/sw/bin/tofu -chdir=tofu apply -var-file="hosts/$(hostname -s).tfvars"

upgrade-guests *guests:
    ./scripts/guests.sh "$@"

upgrade-host:
    doas systemctl start --wait nixos-upgrade.service

manage-secrets *args:
    ./scripts/secrets.sh "$@"

# 全recipient.txtから.sops.yamlを再生成する
regenerate-sops:
    ./scripts/regenerate-sops.sh

install-host configuration target:
    ./scripts/install-host.sh "$@"

# flake.lockとkernel configを更新する
update-flake:
    ./scripts/update-flake.sh
    just _check-nix
