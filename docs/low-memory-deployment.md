# 低メモリ環境へのデプロイ

ホストやゲストでkernelなどをビルドできない場合は、同じarchitectureの管理端末でNixOS toplevelとclosureをビルドして転送する。

## ホスト

管理端末のリポジトリrootで実行する。`HOST_CONFIG`はflake attributeへ置換する。

```bash
(
  set -euo pipefail
  HOST='example-host'

  out=$(
    nix build --no-link --print-out-paths \
      ".#nixosConfigurations.${HOST}.config.system.build.toplevel"
  )

  nix-store --export $(nix-store --query --requisites "$out") |
    ssh -T "me@${HOST}" \
      'umask 077; cat > ~/.nixos-system.nar'

  printf '\033Ptmux;\033\033]9;archiveの転送が完了しました。\033\033\\\033\\' >/dev/tty
  printf 'doas認証を開始するにはEnterを押してください: ' >/dev/tty
  IFS= read -r _ </dev/tty

  ssh -t "me@${HOST}" \
    "doas sh -c 'nix-store --import < /home/me/.nixos-system.nar >/dev/null &&
      rm -f /home/me/.nixos-system.nar &&
      nix-env --profile /nix/var/nix/profiles/system --set \"$out\" &&
      \"$out/bin/switch-to-configuration\" switch'"
)
```

archiveは`/home/me/.nixos-system.nar`へmode `0600`で置かれるので、doasが失敗したら同じ`out`を指定して2番目の`ssh -t`だけ再実行できる。importに失敗した場合は手動で削除する。

この方法では`me`をNix daemonの`trusted-users`へ追加しない。`trusted-users`はパスワードレスroot相当の権限を持つので、それに追加するくらいなら毎回rootとして認証する。

## Incusゲスト

ゲストにはSSH serverがない。Incusホストを中継し、ゲスト内のroot `nix-store`へ直接送る。

aracha-ovhの全ゲストを管理端末で先にビルドし、各ゲストに存在しないstore pathだけを転送してから一括でactivationする。

```bash
just deploy-guest-closures me@aracha-ovh
```

SSH先の短いhostnameに対応する`tofu/hosts/HOST.tfvars`からguest一覧を取得する。全closureとSOPS暗号文を転送し、各guestをactivationする。

## ビルドを確認する。

```bash
nix flake check --no-build
nix build .#nixosConfigurations.HOST_CONFIG.config.system.build.toplevel
nix build .#nixosConfigurations.GUEST.config.system.build.toplevel
```

`nix copy --to ssh-ng://me@HOST`を使うには、通常`me`をtarget Nix daemonのtrusted userにするか、署名鍵を設定する必要がある。このリポジトリではNix archiveをrootでimportする。
