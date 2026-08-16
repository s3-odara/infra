# シークレット管理

管理者の復旧鍵にはYubiKey上のPGP鍵を使う。各ゲストは専用のage鍵で起動時に復号する。

```text
secrets/guests/HOST/GUEST/
├── recipient.txt       # ゲストage鍵の公開recipient
├── identity.sops.json  # PGPで暗号化したage秘密鍵
└── secrets.sops.yaml   # PGPとゲストage鍵に暗号化した実データ
```

平文とage秘密鍵をGitやNix storeへ入れない。

## 初期化

管理端末からIncusホストを操作する場合：

```bash
just manage-secrets --target me@HOST init GUEST
```

GPG agent forwarding済みのIncusホストで実行する場合：

```bash
just manage-secrets init GUEST
```

スクリプトはage鍵を作り、秘密鍵をPGP recipientへ暗号化してGit作業ツリーに保存する。公開recipientは`recipient.txt`へ保存し、`.sops.yaml`は自動生成される。必要なら`just regenerate-sops`で明示的に再生成できる。手動では編集しない。

平文のage鍵はゲストの次の場所へ入る。

```text
/var/lib/sops-nix/key.txt
```

続いて管理端末上で実データを作成する。

```bash
nix run .#sops -- edit secrets/guests/HOST/GUEST/secrets.sops.yaml
```

`sops edit`はsecretの項目を検査しない。現在のNixOS構成が使うkeyは次のとおり。

```yaml
# Prosody
turn_external_secret: ...
ntfy_topic: ...
r2_access_key_id: ...
r2_secret_access_key: ...
restic_repository_password: ...

# WireGuard
wg0_private_key: ...
peer_10_0_0_2_psk: ...
peer_10_0_0_3_psk: ...
```

`.sops.yaml`と暗号文をcommitしてpushする。Incusホストのcheckoutを更新してから対象ゲストへ配送する。

```bash
just upgrade-guests GUEST
```

## 編集

```bash
nix run .#sops -- edit secrets/guests/HOST/GUEST/secrets.sops.yaml
```

暗号文をcommit、pushした後に`just upgrade-guests GUEST`を実行する。ゲストの`system.autoUpgrade`だけでは、ホスト上のGitにある暗号文をゲストへ配送できない。

## ゲスト再作成

Gitに保存した`identity.sops.json`から同じage鍵を戻す。

```bash
just manage-secrets --target me@HOST restore GUEST
```

スクリプトは既存のage鍵を上書きしない。別の鍵が残っている場合は、状況を確認してから手動で対処する。
