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
  read -r -p 'doas認証を開始するにはEnterを押してください: ' _ </dev/tty

  ssh -t "me@${HOST}" \
    "doas sh -c 'nix-store --import < /home/me/.nixos-system.nar >/dev/null &&
      rm -f /home/me/.nixos-system.nar &&
      nix-env --profile /nix/var/nix/profiles/system --set \"$out\" &&
      \"$out/bin/switch-to-configuration\" switch'"
)
```

最初のSSH接続はbinary archiveをTTYなしで送る。転送完了時にtmux passthrough経由のOSC 9でfootのdesktop notificationを送り、Enter入力を待つ。それから2番目の接続でdoas認証、import、profile更新、activationを行う。待機中は2番目のSSH接続をまだ開始していないため、認証待ちのtimeoutは発生しない。tmuxでは`allow-passthrough`を有効にしておく。

archiveは`/home/me/.nixos-system.nar`へmode `0600`で置く。2番目のSSH接続またはdoas認証に失敗してもarchiveは残るため、転送部分を再実行せず、同じ`out`を指定して2番目の`ssh -t`だけを再実行できる。importに失敗した場合は手動で削除する。

この方法は`me`をNix daemonの`trusted-users`へ追加しない。`trusted-users`はパスワードレスroot相当の権限を持つので。

## Incusゲスト

ゲストにはSSH serverがない。Incusホストを中継し、ゲスト内のroot `nix-store`へ直接送る。

```bash
(
  set -euo pipefail
  HOST='me@example-host'
  GUEST='example-guest'

  out=$(
    nix build --no-link --print-out-paths \
      ".#nixosConfigurations.${GUEST}.config.system.build.toplevel"
  )

  nix-store --export $(nix-store --query --requisites "$out") |
    ssh -T "$HOST" \
      "incus exec -T \"$GUEST\" -- nix-store --import >/dev/null"
  ssh -t "$HOST" \
    "incus exec -T \"$GUEST\" -- \
       nix-env --profile /nix/var/nix/profiles/system --set \"$out\" && \
     incus exec -T \"$GUEST\" -- \
       \"$out/bin/switch-to-configuration\" switch"
)
```

`GUEST`にはIncus instance名とflake attributeの両方で使う名前を入れる。Incus `exec`はゲスト内でrootとして実行される。

## ビルドだけ確認する

```bash
nix flake check --no-build
nix build .#nixosConfigurations.HOST_CONFIG.config.system.build.toplevel
nix build .#nixosConfigurations.GUEST.config.system.build.toplevel
```

`nix copy --to ssh-ng://me@HOST`を使うには、通常`me`をtarget Nix daemonのtrusted userにするか、署名鍵を設定する必要がある。このリポジトリではNix archiveをrootでimportする。
