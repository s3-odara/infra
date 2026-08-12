# infra

NixOSホストにIncusゲストを作り、各ゲストへNixOS構成を適用する。

```text
hosts/       ホストのNixOS構成
guests/      ゲストのNixOS構成
tofu/        Incusのnetwork、instance、ACL、forward、storage
secrets/     SOPS暗号文
scripts/     Makeから呼ぶ処理
```

## デプロイ

Incusホストのリポジトリrootで実行する。

```bash
make plan
make deploy
```

`make deploy`はOpenTofuを適用した後、暗号文を各ゲストへ送り、NixOS構成を適用する。

個別の処理も実行できる。

```bash
make tofu-apply
make guests GUESTS=prosody
make host-update
make help
```

## ドキュメント

- [構成とホスト・ゲストの追加](docs/architecture.md)
- [初回導入](docs/installation.md)
- [運用と復旧](docs/operations.md)
- [シークレット管理](docs/secrets.md)
- [低メモリ環境へのデプロイ](docs/low-memory-deployment.md)
