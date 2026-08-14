# IPv6実装方針

現在のOpenTofu構成はIncus bridgeのIPv6を無効にしている。IPv6を有効にする前に、上流ネットワークがprefixをどうホストへ渡すか確認する。

## 設計規則

IPv6対応は次の規則に従う。

- 上流ネットワークとの差は`hosts/HOST/configuration.nix`で処理する。
- Incusで使うホスト固有値は`tofu/hosts/HOST.tfvars`に置く。
- Incus resourceの構造差は`tofu/*.tf`で接続方式ごとに分岐する。
- OpenTofuの分岐にVultrやConoHaなどのprovider名を使わない。
- guestのNixOS構成にprovider固有設定を入れない。
- 各設定値の正本を一つにする。境界をまたぐため同じ値を複数箇所へ書く場合は、正本と複製先を記録し、検査できる不一致は検査する。
- 一つの接続方式しか実装していない間はmodeを作らない。二つ目の方式を追加するときに、接続方式を表すmodeを導入する。
- 実在するホストが必要とする方式だけ実装する。

抽象化を後から追加できるように責務を分ける。将来使うかもしれない接続方式の変数やresourceは先に作らない。

## 責務

上流ネットワーク、Incus network、ゲストOSの設定を分ける。

`hosts/HOST/configuration.nix`はホストと上流ネットワークの接続を管理する。

- uplinkのaddress、gateway、route、MTU
- DHCPv6とRouter Advertisementの受信
- IPv6 forwarding
- ホストのfirewall

`tofu/*.tf`と`tofu/hosts/HOST.tfvars`はIncus内のネットワークを管理する。

- Incus bridgeのprefix、RA、DHCPv6
- ゲストのaddressとNIC
- network ACL
- bridgeへ接続するparent interface

`guests/GUEST/configuration.nix`はゲスト側の受信設定とサービスを管理する。ゲストはVultrやConoHaなどのprovider名を参照しない。

- RAとDHCPv6の受信
- サービスのIPv6 listen address
- ゲスト内のfirewall

同じproviderでも契約やリージョンによってIPv6の提供方法が異なることがある。guest IPv6はIncus ACLを維持できる接続方式だけに対応する。

## DHCPとRA

DHCPとRAは区間ごとに管理者が異なる。

| 区間 | 管理場所 |
| --- | --- |
| 上流ネットワークからホスト | `hosts/HOST/configuration.nix` |
| Incus networkからゲスト | `tofu/*.tf`と`tofu/hosts/HOST.tfvars` |
| ゲストのclient | `guests/GUEST/configuration.nix` |

`routed-prefix`ではIncus bridgeを独立したRAまたはDHCPv6 serverとして扱う。`l2-bridge`では上流ルーターのRAまたはDHCPv6をguestが直接使う。

公開サーバーのaddressはDNSのAAAA recordと一致する必要がある。固定addressをIncusから配る場合はtfvarsを割り当ての正本とし、guestのNixOS構成に同じaddressを重ねて書かない。`l2-bridge`でaddressが変わる場合はDDNSを使う。

## 対応する接続方式

### `routed-prefix`

上流ルーターがguest用prefix全体をIncus hostへrouteする方式を優先する。Incus managed bridgeにprefixを設定し、各guestへpublic IPv6 addressを割り当てる。IPv6 NATとnetwork forwardは使わない。Incus ACLをIPv4と同じ場所で管理できる。

実装前に次を確認する。

- prefixとprefix length
- next hopまたはgateway
- prefix全体がhostへrouteされていること
- source addressや追加addressに対するproviderの制限

### `l2-bridge`

上流networkが複数MAC addressを正式に許可する場合は、物理NICまたはVLANをLinux bridgeへ参加させ、Incus bridged NICを接続できる。bridged NICにはIncus ACLを適用する。

自宅LANでは専用VLANを使う。VPSでは複数MACとpromiscuous modeがproviderの仕様として保証される場合だけ採用する。動作確認だけでは採用しない。

上流ルーターがRAまたはDHCPv6を提供する。OpenTofuは動的なprefixやguest addressを管理しない。公開guestのaddressが変わる場合は、OpenTofuとは別にDDNSを管理する。

## 検証したが採用しない方式

### `routed-nic`

ConoHa VPSでは、割り当てられた追加IPv6をIncus routed NICへ設定し、外向き通信と外部からの通信が通ることを確認した。Incusはguestごとのrouteとproxy NDPを管理できる。

このリポジトリでは採用しない。routed NICはIncus network ACLに対応せず、IPv4とIPv6でservice policyの管理場所が分かれる。

### OVN

OVN networkはIncus ACLに対応し、on-link addressを扱う構成も設計できる。現在の三つのguestには導入しない。

OVNを使うにはOpen vSwitch、OVN Northbound/Southbound DB、`ovn-northd`、`ovn-controller`が要る。DBを永続化せず再生成する運用も可能だが、OVN DBだけを失うとOpenTofu state、Incus DB、OVN DBの状態が一致しなくなる。再生成時はOVN networkとNICを削除またはforce-replaceして作り直す手順が要る。

複数network、複数host、guestから変更できないeast-west policyが必要になった時点で再検討する。

## 対応しない方式

`routed-prefix`と`l2-bridge`のどちらも使えないhostではguestのIPv6を有効にしない。host自身のIPv6は利用できる。

共通構成では次の方式に対応しない。

- NAT66とIPv6 network forward
- OpenTofu外で管理するguest単位のproxy NDPとroute
- 動的prefixをtfvarsへ書き戻す処理
- provider APIによるaddressまたはMACの登録
- provider名によるresource分岐

ホスト用の`/128`しか使えない場合や、providerが追加source addressを拒否する場合はguestをIPv4-onlyとする。IPv6 tunnelを使う場合はhostまたは外部ルーターで終端し、Incus hostへ固定prefixをrouteする。OpenTofuからは`routed-prefix`として扱う。

動的なDHCPv6 Prefix Delegationは静的なtfvarsでは管理しない。`l2-bridge`で上流ルーターのRAをguestへ渡すか、guestのIPv6を無効にする。

## 値の配置

値は次の場所に置く。

- 上流から指定されたホストaddress、gateway、routeはhostのNixOS構成
- Incusで使うprefix、guest address、uplink名、parent bridge名は必要な方式のtfvars
- RA、DHCPv6、NIC、ACLの生成規則は共通のOpenTofu構成
- RAやDHCPv6を受ける設定とserviceのlisten設定はguestのNixOS構成

IPv4の`public_ports`はhost addressからguest IPv4へのforwardとmanaged NICのACLに使う。public IPv6もIncus ACLで同じportを許可する。IPv6 forwardは作らない。

`private_ports`の`source = "network"`をIPv6へ対応させる場合は、IPv4とIPv6のnetwork prefixからACL ruleをそれぞれ生成する。明示したCIDRは、そのaddress familyだけに適用する。

ICMPv6を一括で拒否してはならない。Neighbor Discovery、Router Advertisement、Packet Too Big、Destination Unreachable、Time Exceededに必要な通信を通す。ACLを絞る前に、Incus NICへACLを適用した状態でRA、DHCPv6、NDP、Path MTU Discoveryを確認する。

複数uplink、policy routing、VRFは共通modeへ含めない。対象hostのNixOS構成へ明示する。Incus側の構造まで変わる場合は、`routed-prefix`または`l2-bridge`として表現できるときだけOpenTofuへ追加する。

## 実装手順

対象ホストで上流のaddressとrouteを確認する。

```bash
ip -6 address
ip -6 route
```

providerの資料または管理画面でprefixの提供方法も確認する。出力に`/64`があるだけではrouted prefixと判断できない。

1. 上流の接続方式を決める。
2. hostのNixOS構成へuplink、route、forwarding、firewallを追加する。
3. tfvarsへ接続方式が必要とするprefix、guest address、uplink名、parent bridge名を追加する。
4. OpenTofuへ必要なnetwork、NIC、ACLと入力検証を追加する。
5. guestがRAまたはDHCPv6を受け、期待したaddressとdefault routeを持つことを確認する。
6. 外向き通信、外部からの公開port、ICMPv6、Path MTU Discoveryを確認する。
7. 固定addressではDNSのAAAA recordを変更する。動的addressではDDNSの更新を確認する。

WireGuard service自体をIPv6で公開する変更と、VPN clientへIPv6を配る変更は分ける。後者にはVPN内のaddress設計、forwarding、filteringが別に必要になる。
