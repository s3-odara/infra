# シークレット管理

管理者の復旧鍵にはYubiKey上のPGP鍵を使う。各ゲストは専用のage鍵で起動時に復号する。

```text
secrets/guests/HOST/GUEST/
├── identity.sops.json  # PGPで暗号化したage秘密鍵
└── secrets.sops.yaml   # PGPとゲストage鍵に暗号化した実データ
```

平文とage秘密鍵をGitやNix storeへ入れない。

## 初期化

管理端末からIncusホストを操作する場合：

```bash
./scripts/secrets.sh --target me@HOST init GUEST
```

GPG agent forwarding済みのIncusホストで実行する場合：

```bash
./scripts/secrets.sh init GUEST
```

スクリプトはage鍵を作り、秘密鍵をPGP recipientへ暗号化してGit作業ツリーに保存する。平文のage鍵はゲストの次の場所へ入る。

```text
/var/lib/sops-nix/key.txt
```

表示された`age1...` recipientを`.sops.yaml`へ追加する。

```yaml
- path_regex: ^secrets/guests/HOST/GUEST/secrets\.sops\.yaml$
  key_groups:
    - pgp:
        - *admin_pgp
      age:
        - age1...
```

実データを作成する。

```bash
./scripts/secrets.sh --target me@HOST edit GUEST
```

`scripts/secrets.sh`はsecretの項目を検査しない。現在のNixOS構成が使うkeyは次のとおり。

```yaml
# Prosody
turn_external_secret: ...

# WireGuard
wg0_private_key: ...
peer_10_0_0_2_psk: ...
peer_10_0_0_3_psk: ...
```

`.sops.yaml`と暗号文をcommitしてpushする。Incusホストのcheckoutを更新してから対象ゲストへ配送する。

```bash
make guests GUESTS=GUEST
```

## 編集

```bash
./scripts/secrets.sh --target me@HOST edit GUEST
```

暗号文をcommit、pushした後に`make guests GUESTS=GUEST`を実行する。ゲストの`system.autoUpgrade`だけでは、ホスト上のGitにある暗号文をゲストへ配送できない。

## ゲスト再作成

Gitに保存した`identity.sops.json`から同じage鍵を戻す。

```bash
./scripts/secrets.sh --target me@HOST restore GUEST
```

スクリプトは既存のage鍵を上書きしない。別の鍵が残っている場合は、状況を確認してから手動で対処する。
