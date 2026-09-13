# 運用と復旧

## Just tasks

```bash
just help
just check
just deploy-guests
just apply-tofu
just apply-cloudflare
just upgrade-guests
just upgrade-guests prosody wireguard
just upgrade-host
just update-eturnal
just update-matrix-bot
just update-providers
just update-sygnal
just update-flake
```

- `check`: Nix、OpenTofu、シェル構文を検証する
- `deploy-guests`: OpenTofuを適用し、全ゲストへNixOS構成を適用する
- `apply-tofu`: Incus用OpenTofuだけを適用する
- `apply-cloudflare`: 管理端末からR2 Bucket Lock/Lifecycleを適用する
- `upgrade-guests`: OpenTofuを触らず、全ゲストまたは指定したゲストを適用する
- `upgrade-host`: ホストの`nixos-upgrade.service`を起動して完了を待つ
- `update-eturnal`: eturnalの最新releaseとRebar3依存hashへ更新してpackageをbuildする。
- `update-matrix-bot`: Matrix botの`Cargo.toml`と`Cargo.lock`を更新して単体packageをbuildする。
- `update-providers`: Incus・Cloudflare providerを最新版へ更新して`構成を検証する。
- `update-sygnal`: Sygnalの最新releaseとsource hashへ更新し、単体packageをbuildする。更新時は上流のPythonバージョンと個別に定義しているパッケージの上流での固定バージョンを確認し、個別定義が互換性問題で依然必要かテストする。
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

## Guestログ集約

Guestのjournalはhostに転送する。送信元も含めて偽装はできるがguestから削除はできない。

```bash
# remote journal全体、または送信側が申告したhostnameで検索
journalctl --directory=/var/log/journal/remote --since today
journalctl --directory=/var/log/journal/remote _HOSTNAME=GUEST

# uploaderとreceiverを確認
incus exec GUEST -- systemctl status systemd-journal-upload.service
systemctl status systemd-journal-remote.socket systemd-journal-remote.service
```

## Matrix bot

### 初期セットアップ

guest側のmatrixはバックアップしていないのでguestをボンバーさせたらbot用のtokenを作り直し。

1. guest DBを捨てる

   ```bash
   incus exec tuwunel-guest -- systemctl stop tuwunel
   # /var/lib/tuwunel は systemd の StateDirectory による /var/lib/private/tuwunel への symlink
   incus exec tuwunel-guest -- rm -rf /var/lib/private/tuwunel
   incus exec tuwunel-guest -- systemctl start tuwunel
   ```

2. bot用アカウントをtuwunelコンテナ越しに登録。

   ```bash
   incus exec tuwunel -- curl -s http://10.77.3.17:8008/_matrix/client/v3/register \
     -H 'Content-Type: application/json' \
     -d '{"username":"invite-bot-guest","password":"<任意の長いランダム文字列>","auth":{"type":"m.login.dummy"}}'
   ```

   レスポンスの`access_token`を控える。

3. secretを追加する。

   ```bash
   nix run .#sops -- edit secrets/guests/aracha-ovh/tuwunel/secrets.sops.yaml
   ```

   ```yaml
   guest_registration_admin_token: <手順2のaccess_token>
   guest_registration_sentinel: <openssl rand -hex 24 の出力>
   ```

4. `just upgrade-guests tuwunel`でbotを再起動、guest tuwunelも再起動する。

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

## バックアップしないが依存してる状態

ACMEの秘密鍵とアカウントはバックアップしないが、CAAのaccounturi, DANE for XMPPのTLSA、CT log監視がそれに依存しているので、guestを消して再生成した時は登録し直す。

accounturi
```bash
for guest in nginx prosody rtc; do
  echo "=== $guest ==="
  incus exec "$guest" -- sh -ceu '
    nix shell nixpkgs#jq -c sh -ceu '"'"'
      find /var/lib/acme/.lego/accounts \
        -type f -name account.json \
        -exec jq -er ".registration.uri" {} \;
    '"'"'
  '
done
```

TLSA, CT log (SPKI SHA-256)
```bash
for guest in nginx prosody rtc; do
   echo "=== $guest ==="

   incus exec "$guest" -- \
     nix shell nixpkgs#openssl -c bash -o pipefail -ceu '
       for cert in /var/lib/acme/*/fullchain.pem; do
         printf "%s: " "$(basename "$(dirname "$cert"))"
         openssl x509 -in "$cert" -pubkey -noout |
           openssl pkey -pubin -outform DER |
           sha256sum
       done
     '
 done
```
