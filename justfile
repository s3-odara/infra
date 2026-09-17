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
      deploy-guest-closures   Build and remotely activate aracha-ovh guests
      manage-secrets          Manage host and guest secrets

      apply-tofu              Apply only the Incus OpenTofu configuration
      apply-cloudflare        Apply the Cloudflare R2 policies locally
      apply-github            Apply the GitHub repository settings locally
      upgrade-guests          Upgrade guest configurations
      upgrade-host            Upgrade the host configuration
      regenerate-sops         Regenerate .sops.yaml
      update-eturnal          Update eturnal and its locked dependencies
      update-rust             Update Rust dependencies
      update-providers         Update OpenTofu provider locks
      update-sygnal           Update Sygnal
      update-go               Update Go dependencies
      update-web-clients      Update Sable
      update-flake            Update flake inputs and generated files

    Examples:
      just install-host mecha-vultr root@HOST
      just apply-tofu
      just upgrade-guests
      just apply-github
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

check: _check-nix _check-tofu _check-cloudflare _check-github _check-shell

_check-nix:
    nix flake check "path:{{ repo_root }}"
    nix eval --json "path:{{ repo_root }}#nixosConfigurations" --apply 'configs: builtins.mapAttrs (_: cfg: cfg.config.system.build.toplevel.drvPath) configs' >/dev/null
    git ls-files -z -- '*.nix' | xargs -0 -r nix fmt -- --check

_check-tofu:
    nix shell "path:{{ repo_root }}#opentofu" -c sh -eu -c '\
      tofu=$(command -v tofu); \
      "$tofu" -chdir=tofu fmt -check -recursive; \
      "$tofu" -chdir=tofu init -backend=false -lockfile=readonly; \
      "$tofu" -chdir=tofu validate; \
      for var_file in tofu/hosts/*.tfvars; do \
        "$tofu" -chdir=tofu test -var-file="${var_file#tofu/}"; \
      done'

_check-cloudflare:
    nix shell "path:{{ repo_root }}#opentofu" -c sh -eu -c '\
      tofu=$(command -v tofu); \
      "$tofu" -chdir=cloudflare fmt -check -recursive; \
      "$tofu" -chdir=cloudflare init -backend=false -lockfile=readonly; \
      "$tofu" -chdir=cloudflare validate'

_check-github:
    nix shell "path:{{ repo_root }}#opentofu" -c sh -eu -c '\
      tofu=$(command -v tofu); \
      "$tofu" -chdir=github fmt -check -recursive; \
      "$tofu" -chdir=github init -backend=false -lockfile=readonly; \
      "$tofu" -chdir=github validate'

_check-shell:
    find scripts modules -type f -name '*.sh' -print0 | xargs -0 -r bash -n
    find scripts modules -type f -name '*.sh' -print0 | xargs -0 -r nix shell "path:{{ repo_root }}#shfmt" -c shfmt -d -i 2

deploy-guest-closures host:
    ./scripts/deploy-guest-closures.sh "$@"

apply-tofu:
    doas /run/current-system/sw/bin/tofu -chdir=tofu init
    doas /run/current-system/sw/bin/tofu -chdir=tofu apply -var-file="hosts/$(hostname -s).tfvars"

apply-cloudflare:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN on the administrator workstation}"
    nix shell "path:{{ repo_root }}#opentofu" -c tofu -chdir=cloudflare init
    nix shell "path:{{ repo_root }}#opentofu" -c tofu -chdir=cloudflare apply

apply-github *tofu_args:
    #!/usr/bin/env bash
    set -euo pipefail

    encrypted_key="{{ repo_root }}/secrets/github-apps/infra-tofu.private-key.sops.json"
    nix shell "path:{{ repo_root }}#sops" "path:{{ repo_root }}#opentofu" -c \
      bash -euc '
        export TF_VAR_github_app_pem_file="$(
          sops decrypt --input-type json --output-type binary "$1"
        )"
        shift
        unset GITHUB_TOKEN GH_TOKEN
        tofu -chdir=github init
        tofu -chdir=github apply "$@"
      ' bash "$encrypted_key" "$@"

upgrade-guests *guests:
    nix shell "path:{{ repo_root }}#jq" -c ./scripts/guests.sh "$@"

upgrade-host:
    #!/usr/bin/env -S nix shell "path:{{ repo_root }}#jq" -c bash
    set -euo pipefail

    metadata=$(nix flake metadata --refresh --no-update-lock-file --json \
      github:s3-odara/infra/main)
    commit=$(jq -er '.locked.rev | select(type == "string")' <<<"$metadata")
    source=$(jq -er '.path | select(type == "string")' <<<"$metadata")
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "Could not resolve GitHub main" >&2; exit 1; }
    [[ $source == /nix/store/* && -d $source ]] || { echo "GitHub main snapshot path is invalid" >&2; exit 1; }
    echo "Using GitHub main commit $commit from $source"
    flake="github:s3-odara/infra/$commit#$(hostname -s)"
    doas nixos-rebuild boot --flake "$flake"

    booted="$(readlink /run/booted-system/{initrd,kernel,kernel-modules})"
    built="$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"

    if [[ "$booted" == "$built" ]]; then
      doas nixos-rebuild switch --flake "$flake"
    else
      echo "Kernel, initrd, or kernel modules changed; reboot required."
    fi

manage-secrets *args:
    ./scripts/secrets.sh "$@"

# 全recipient.txtから.sops.yamlを再生成する
regenerate-sops:
    ./scripts/regenerate-sops.sh

install-host configuration target:
    ./scripts/install-host.sh "$@"

# eturnal本体と固定したErlang依存を更新する
update-eturnal:
    nix shell "path:{{ repo_root }}#gh" "path:{{ repo_root }}#jq" -c ./scripts/update-eturnal.sh

# Rust依存をCargo.toml/Cargo.lockともに更新する
update-rust:
    #!/usr/bin/env bash
    set -euo pipefail

    nix shell --inputs-from "path:{{ repo_root }}" nixpkgs#cargo nixpkgs#cargo-edit -c bash -euc '
      for package in matrix-bot check-sygnal-pins; do
        cargo upgrade --manifest-path "packages/$package/Cargo.toml" --incompatible allow
        cargo update --manifest-path "packages/$package/Cargo.toml"
      done
    '

# OpenTofu providerを更新する
update-providers:
    #!/usr/bin/env bash
    set -euo pipefail

    nix shell "path:{{ repo_root }}#opentofu" -c sh -euc '
      tofu -chdir=tofu init -backend=false -upgrade
      tofu -chdir=cloudflare init -backend=false -upgrade
      tofu -chdir=github init -backend=false -upgrade
    '

# Sygnalの署名付きreleaseとupstream lock由来のpinを照合・更新する
update-sygnal:
    nix shell \
      "path:{{ repo_root }}#gh" \
      "path:{{ repo_root }}#gnupg" \
      "path:{{ repo_root }}#jq" \
      "path:{{ repo_root }}#check-sygnal-pins" \
      -c ./scripts/update-sygnal.sh

# Go依存を更新する（現在の対象はweb-client-html）。Go本体はupdate-flakeで更新する
update-go:
    #!/usr/bin/env bash
    set -euo pipefail

    nix shell --inputs-from "path:{{ repo_root }}" \
      "path:{{ repo_root }}#web-client-html.go" nixpkgs#nix-update -c bash -euc '
        export GOTOOLCHAIN=local
        go -C packages/web-client-html get -u ./...
        go -C packages/web-client-html mod tidy
        nix-update --flake --version=skip web-client-html
      '

# Sable OCI attestationを検証し、index digestとamd64取得hashを更新する
update-web-clients:
    nix shell \
      "path:{{ repo_root }}#gh" \
      "path:{{ repo_root }}#jq" \
      "path:{{ repo_root }}#nix-prefetch-docker" \
      "path:{{ repo_root }}#skopeo" \
      -c ./scripts/update-web-clients.sh

# flake.lockとkernel configを更新する
update-flake:
    ./scripts/update-flake.sh
