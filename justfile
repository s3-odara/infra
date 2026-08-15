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
      plan-tofu               Validate the OpenTofu configuration
      deploy-guests           Deploy Incus resources and guest configurations
      manage-secrets          Manage guest secrets

      apply-tofu              Apply only the OpenTofu configuration
      upgrade-guests          Upgrade guest configurations
      upgrade-host            Upgrade the host configuration
      regenerate-sops         Regenerate .sops.yaml
      update-flake            Update flake inputs and generated files

    Examples:
      just install-host incus-01 root@HOST
      just plan-tofu
      just deploy-guests
      just manage-secrets init prosody

    Run `just help manage-secrets` for secret management usage.
    EOF
        ;;
      manage-secrets)
        cat <<'EOF'
    Usage:
      just manage-secrets [--target USER@HOST] <init|restore|edit> GUEST

    Commands:
      init      Create an age identity
      restore   Restore an age identity to a guest
      edit      Edit the SOPS-encrypted secrets

    Examples:
      just manage-secrets init prosody
      just manage-secrets edit prosody
      just manage-secrets --target me@HOST restore prosody
    EOF
        ;;
      *)
        printf 'Unknown help topic: %s\n' "$1" >&2
        printf 'Available topics: manage-secrets\n' >&2
        exit 1
        ;;
    esac

# Nix、OpenTofu、シェルスクリプトを順番に静的検証する
check: _check-nix _check-tofu _check-shell

_check-nix:
    nix flake check --no-build "path:{{ repo_root }}"
    nix eval --json "path:{{ repo_root }}#nixosConfigurations" --apply 'configs: builtins.mapAttrs (_: cfg: cfg.config.system.build.toplevel.drvPath) configs' >/dev/null

# tfvarsや実環境を使わずOpenTofuの書式と構成を検証する
_check-tofu:
    nix shell "path:{{ repo_root }}#opentofu" -c sh -eu -c '\
      tofu=$(command -v tofu); \
      "$tofu" -chdir=tofu fmt -check; \
      doas "$tofu" -chdir=tofu init -backend=false -lockfile=readonly; \
      "$tofu" -chdir=tofu validate'

_check-shell:
    bash -n scripts/*.sh

# 実行中のホストに対するIncusリソースの変更予定を表示する
plan-tofu:
    ./scripts/tofu.sh plan

# Incusリソースを適用してから全ゲストを更新する。初回デプロイにも。
deploy-guests:
    ./scripts/tofu.sh apply
    ./scripts/guests.sh

# Incusリソースの変更をOpenTofuで適用する
apply-tofu:
    ./scripts/tofu.sh apply

# 全ゲスト、または指定したゲストを更新する（例: just upgrade-guests prosody wireguard）
upgrade-guests *guests:
    ./scripts/guests.sh "$@"

# NixOSホストの更新を開始して完了を待つ
upgrade-host:
    doas systemctl start --wait nixos-upgrade.service

# ゲストのシークレットを管理する（例: just manage-secrets --target me@HOST init prosody）
manage-secrets *args:
    ./scripts/secrets.sh "$@"

# 全recipient.txtから.sops.yamlを再生成する
regenerate-sops:
    ./scripts/regenerate-sops.sh

# ホストを新規インストールする（例: just install-host incus-01 root@HOST）
install-host configuration target:
    ./scripts/install-host.sh "$@"

# flake.lockとkernel configを更新する
update-flake:
    ./scripts/update-flake.sh
    just _check-nix
