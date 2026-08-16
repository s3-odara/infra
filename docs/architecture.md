# 構成

## ホスト名

ホスト名を`HOST`とする。次の名前を揃える。

```text
hosts/HOST/
tofu/hosts/HOST.tfvars
flake.nix の nixosConfigurations.HOST
```

`just apply-tofu`と`scripts/guests.sh`は実行中のホスト名に対応するtfvarsを使う。各ホストに`tofu/hosts/HOST.tfvars`を1ファイル置く。

`hosts/HOST/`はホストOSを定義する。`tofu/hosts/HOST.tfvars`は、そのホスト上のIncus networkとゲストを定義する。ファイル名を揃える規約はあるが、一方から他方を生成する処理はない。

## ゲスト名

ゲスト名を`GUEST`とする。次の名前を揃える。

```text
guests/GUEST/configuration.nix
flake.nix の nixosConfigurations.GUEST
tofu/hosts/HOST.tfvars の guests.GUEST
secrets/guests/HOST/GUEST/    # シークレットを使う場合
```

ホストとゲストの対応は`tofu/hosts/HOST.tfvars`の`guests` mapで決まる。Incus instanceはOpenTofuだけで作成し、ゲスト名には小文字英数字と`-`からなる63文字以下のDNS labelを使う。

```hcl
guests = {
  prosody = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.1.10"
    cpu_allowance = "100ms/100ms"
    memory        = "1GiB"
    disk_size     = "10GiB"

    public_ports = [
      {
        protocol = "tcp"
        port     = 5222
      },
    ]
    private_ports = []
  }
}
```

`public_ports`と`private_ports`は、使わない場合も`[]`を明記する。private portの`source`も必須で、同じIncus network全体を許可するときは`source = "network"`、範囲を限定するときはCIDRを指定する。

同名ゲストを複数ホストに置くときは、同じNixOS構成を使う。シークレットは`HOST/GUEST`ごとに分ける。

## ホストを追加する

`HOST`について次を追加する。

1. `hosts/HOST/configuration.nix`
2. `hosts/HOST/disko.nix`
3. `flake.nix`の`nixosConfigurations.HOST`
4. `tofu/hosts/HOST.tfvars`

必要に応じて`hardening.nix`、`kernel.nix`、`kernel.config`も置く。既存の`hosts/incus-01/`を複製する場合は、ディスク名、boot方式、kernel module、public IP、Incus subnetを対象ホストに合わせる。

## ゲストを追加する

`GUEST`について次を追加する。

1. `guests/GUEST/configuration.nix`
2. `flake.nix`の`nixosConfigurations.GUEST`
3. 配置先の`tofu/hosts/HOST.tfvars`に`guests.GUEST`
4. シークレットを使う場合はage identityを初期化し、暗号文を作成
