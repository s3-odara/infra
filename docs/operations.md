# 運用と復旧

## Just tasks

```bash
just help
just check
just deploy-guests
just apply-tofu
just upgrade-guests
just upgrade-guests prosody wireguard
just upgrade-host
just update-eturnal
just update-matrix-invite-bot
just update-flake
```

- `check`: Nix、OpenTofu、シェル構文を検証する
- `deploy-guests`: OpenTofuを適用し、全ゲストへNixOS構成を適用する
- `apply-tofu`: OpenTofuだけを適用する
- `upgrade-guests`: OpenTofuを触らず、全ゲストまたは指定したゲストを適用する
- `upgrade-host`: ホストの`nixos-upgrade.service`を起動して完了を待つ
- `update-eturnal`: eturnalの最新releaseとRebar3依存hashへ更新してpackageをbuildする。
- `update-matrix-invite-bot`: Matrix invite botの`Cargo.lock`を更新し、単体packageをbuildする。deployやsecretの変更は行わない。
- `update-flake`: flake inputと生成済みkernel configを更新し、Nix構成を評価する

ホストとゲストでは`system.autoUpgrade`も動く。ゲストの自動更新はSOPS暗号文を配送しない。暗号文を変更したら`just upgrade-guests GUEST`を実行する。

## 状態とログ

ホスト：

```bash
systemctl status nixos-upgrade.timer nixos-upgrade.service
journalctl -u nixos-upgrade.service -b
nixos-rebuild list-generations
```

ゲスト：

```bash
incus list
incus info GUEST
incus exec GUEST -- systemctl status nixos-upgrade.timer nixos-upgrade.service
incus exec GUEST -- journalctl -u nixos-upgrade.service -b
incus exec GUEST -- nixos-rebuild list-generations
```

## 手動更新

ゲスト：

```bash
incus exec GUEST -- \
  nixos-rebuild switch --refresh \
  --option experimental-features "nix-command flakes" \
  --flake github:s3-odara/infra#GUEST
```

ホスト：

```bash
ssh -t me@HOST \
  'doas nixos-rebuild switch --refresh --flake github:s3-odara/infra#HOST_CONFIG'
```

kernel更新を次回bootへ登録して再起動する。

```bash
ssh -t me@HOST \
  'doas nixos-rebuild boot --refresh --flake github:s3-odara/infra#HOST_CONFIG && \
   doas systemctl reboot'
```

## rollback

ホスト：

```bash
doas nixos-rebuild switch --rollback

# 次回bootに設定して再起動
doas nixos-rebuild boot --rollback
doas systemctl reboot
```

ゲストではIncusがrootとしてコマンドを実行する。`doas`は付けない。

```bash
incus exec GUEST -- nixos-rebuild switch --rollback

# 次回bootに設定して再起動
incus exec GUEST -- nixos-rebuild boot --rollback
incus exec GUEST -- systemctl reboot
```

## OpenTofuを直接使う

Justを使わない場合も、stateの所有者を混在させないため全コマンドを`doas`で実行する。事前の検証にはリポジトリrootで`just check`を使う。

```bash
cd tofu
doas /run/current-system/sw/bin/tofu init
doas /run/current-system/sw/bin/tofu apply -var-file=hosts/HOST.tfvars
```
