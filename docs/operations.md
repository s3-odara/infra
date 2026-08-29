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
just update-sygnal
just update-flake
```

- `check`: Nix、OpenTofu、シェル構文を検証する
- `deploy-guests`: OpenTofuを適用し、全ゲストへNixOS構成を適用する
- `apply-tofu`: OpenTofuだけを適用する
- `upgrade-guests`: OpenTofuを触らず、全ゲストまたは指定したゲストを適用する
- `upgrade-host`: ホストの`nixos-upgrade.service`を起動して完了を待つ
- `update-eturnal`: eturnalの最新releaseとRebar3依存hashへ更新してpackageをbuildする。
- `update-matrix-invite-bot`: Matrix invite botの`Cargo.lock`を更新し、単体packageをbuildする。deployやsecretの変更は行わない。
- `update-sygnal`: Sygnalの最新releaseとsource hashへ更新し、単体packageをbuildする。
- `update-flake`: flake inputと生成済みkernel configを更新し、Nix構成を評価する

ホストとゲストでは`system.autoUpgrade`も動く。ゲストの自動更新はSOPS暗号文を配送しない。暗号文を変更したら`just upgrade-guests GUEST`を実行する。

## Sygnal初回デプロイ

Sygnalの初回だけは`just deploy-guests`で一括適用しない。公開経路より先にguest、secret、DNSを準備する。

```bash
# 1. OpenTofuでsygnal guestとACLを作成する。
just apply-tofu

# 2. リポジトリに保管済みのguest age identityを復元する。
# 管理端末から実行する場合は --target me@HOST を付ける。
just manage-secrets restore sygnal

# 3. 暗号文を配送し、Sygnalを起動する。
just upgrade-guests sygnal
incus exec sygnal -- systemctl is-active sygnal.service

# 4. 公開DNSを先に反映する。
just upgrade-guests nsd

# 5. nginx、ACME SAN、SableのPush設定を反映する。
just upgrade-guests nginx
incus exec nginx -- systemctl start --wait acme-matrix.odarah.org.service
```

最後に、公開DNS、証明書SAN、Gateway、Sable設定を確認する。

```bash
getent ahostsv4 push.matrix.odarah.org
openssl s_client -connect push.matrix.odarah.org:443 \
  -servername push.matrix.odarah.org </dev/null 2>/dev/null \
  | openssl x509 -noout -checkhost push.matrix.odarah.org
curl --silent --output /dev/null --write-out '%{http_code}\n' \
  https://push.matrix.odarah.org/health # 404が期待値
curl --fail https://sable.matrix.odarah.org/config.json
```

`sygnal.service`は起動時に内部`/health`を検査する。nginxは公開するのを`/_matrix/push/v1/notify`のみに限定しているため、公開`/health`の404は正常。初回適用後は通常の`upgrade-guests`を使用できる。

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
