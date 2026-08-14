# infra

NixOSホストにIncusゲストを作り、各ゲストへNixOS構成を適用する。

```text
hosts/       ホストのNixOS構成
guests/      ゲストのNixOS構成
tofu/        Incusのnetwork、instance、ACL、forward、storage
secrets/     SOPS暗号文
scripts/     justから呼ぶ処理
```

## デプロイ

Incusホストのリポジトリrootで実行する。

```bash
just check
just plan-tofu
just deploy-guests
```

`just check`はNix、OpenTofu構成、シェル構文を静的に検証する。ホスト固有のtfvarsと実環境との差分は`just plan-tofu`で検証する。

`just deploy-guests`はOpenTofuを適用した後、暗号文を各ゲストへ送り、NixOS構成を適用する。

個別の処理も実行できる。

```bash
just apply-tofu
just upgrade-guests prosody
just upgrade-host
just help
```

## ドキュメント

- [構成とホスト・ゲストの追加](docs/architecture.md)
- [IPv6実装方針](docs/ipv6.md)
- [初回導入](docs/installation.md)
- [運用と復旧](docs/operations.md)
- [シークレット管理](docs/secrets.md)
- [低メモリ環境へのデプロイ](docs/low-memory-deployment.md)
