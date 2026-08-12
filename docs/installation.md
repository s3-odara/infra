# 初回導入

## ホストOS

`nixos-anywhere`が対象ディスクを再partitionする。既存データは消える。

管理端末で実行する。

```bash
make install-host CONFIG=incus-01 TARGET=root@HOST
```

実行時に`me`ユーザーのdoas用パスワードを入力する。パスワードハッシュは一時ディレクトリに生成され、スクリプト終了時に削除される。

## リポジトリ

インストール後は`me`でSSH接続する。管理端末のcommit済みファイルを送る例：

```bash
git archive --format=tar HEAD |
  ssh me@HOST 'mkdir -p ~/infra && tar -xf - -C ~/infra'
```

通常のcloneを使ってもよい。

## Incusとゲスト

ホスト上のリポジトリrootで差分を確認する。

```bash
cd ~/infra
make plan
```

シークレットを使うゲストは、OpenTofuでinstanceを作成した後、初回NixOS適用の前にage identityと暗号文を用意する。

```bash
make tofu-apply
./scripts/secrets.sh init GUEST
```

GPG鍵を管理端末だけで使う場合は、管理端末から実行する。

```bash
./scripts/secrets.sh --target me@HOST init GUEST
```

手順は[シークレット管理](secrets.md)を参照する。

全ゲストへNixOS構成を適用する。

```bash
make guests
```

シークレットを使わない場合や、すでにidentityと暗号文がある場合は、OpenTofuとゲスト適用をまとめて実行できる。

```bash
make deploy
```

`make deploy`は次の順で処理する。

1. OpenTofu `init`、`validate`、`apply`
2. Incusゲストの起動待ち
3. 対応するSOPS暗号文の配送
4. 未構築ゲストへの`nixos-rebuild switch`
5. 構築済みゲストの`nixos-upgrade.service`

OpenTofuは`doas`で実行する。`tofu/`内のstateと生成物はroot所有になる。ゲスト操作には非特権の`me`ユーザーと、この環境のUID別Incus projectを使う。
