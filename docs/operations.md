# 運用と復旧

## Make targets

```bash
make help
make check
make plan
make deploy
make tofu-apply
make guests
make guests GUESTS="prosody wireguard"
make host-update
make update-flake
```

- `check`: Nix、OpenTofu構成、シェル構文を静的に検証する
- `plan`: 実行中のホストに対応するtfvarsを検証し、OpenTofuの差分を表示する
- `deploy`: OpenTofuを適用し、全ゲストへNixOS構成を適用する
- `tofu-apply`: OpenTofuだけを適用する
- `guests`: OpenTofuを触らずゲストを適用する
- `host-update`: ホストの`nixos-upgrade.service`を起動して完了を待つ
- `update-flake`: flake inputと生成済みkernel configを更新し、Nix構成を評価する

`check`のOpenTofu検証はtfvarsや実環境を読まない。ホスト固有の入力値は`plan`または`apply`で検証する。

ホストとゲストでは`system.autoUpgrade`も動く。ゲストの自動更新はSOPS暗号文を配送しない。暗号文を変更したら`make guests GUESTS=GUEST`を実行する。

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

Makeを使わない場合も、stateの所有者を混在させないため全コマンドを`doas`で実行する。

```bash
cd tofu
doas tofu init
doas tofu validate
doas tofu plan -var-file=hosts/HOST.tfvars
doas tofu apply -var-file=hosts/HOST.tfvars
```

## Prosody TLS

証明書の発行と更新は自動化していない。NixOSのProsody moduleは`/etc/prosody/certs`を作成し、Prosodyのdomain別探索を使う。

```text
/etc/prosody/certs/xmpp.odarah.org.{crt,key}
/etc/prosody/certs/conference.xmpp.odarah.org.{crt,key}
/etc/prosody/certs/share.xmpp.odarah.org.{crt,key}
```

完全なcertificate chainと対応するprivate keyを置く。

- directory: `prosody:prosody`, `0750`
- certificate: `prosody:prosody`, `0644`
- private key: `prosody:prosody`, `0600`

更新後に`systemctl reload prosody`を実行する。ACME clientを使う場合は、deploy hookで所有者、mode、reloadを処理する。
