### IncusのIPv4 filteringを使わない

- 実装: `tofu/instances.tf:47-54`
- 理由: Incus 7.3でもIPv4 filteringを有効にするとDHCP OFFERを受信できない。
- 対応: `security.ipv4_filtering`の代わりにMAC filteringとnetwork ACLを使う。
- 撤去条件: 使用中のIncusでIPv4 filteringとDHCPの組み合わせが修正され、実環境で確認できたとき。
- 導入コミット: `f9f34f3` (`fix: 多分incusのバグ？`)

### Prosody 14まで`csi_battery_saver`を使う

- 実装: `guests/prosody/configuration.nix:44-64,204-208`
- 理由: 現在のProsodyでは、移行先にする予定の組み込み`csi_simple`をまだ使わない。
- 対応: Community Moduleの`csi_battery_saver`、`csi_muc_priorities`、`track_muc_joins`をpackageと`extraModules`へ追加する。
- 撤去条件: Prosody 14へ更新したとき。`csi_simple`へ切り替え、`csi_battery_saver`をpackageと`extraModules`から削除し、`csi_grace_period`を有効化する。
- 導入コミット: `bc1342a` (`feat(prosody): save battery`)

### TuwunelがMSC4174を実装するまでSygnalを運用する

- 実装: `guests/sygnal/configuration.nix`, `packages/sygnal/`, `flake.nix`の`sygnal` package、nginxのPush Gateway proxy
- 理由: 現在のTuwunelだけではMSC4174によるWeb Push配信を完結できない。
- 対応: 独立したSygnal guestをPush Gatewayとして運用し、Tuwunelから通知を転送する。
- 撤去条件: TuwunelのMSC4174実装issue `matrix-construct/tuwunel#223`が完成し、Sygnalなしで利用中clientへのWeb Push配信を確認できたとき。
- 撤去対象: Sygnal guest・package・secret・ACL・DNS・nginx proxy・監視と、以下に記載するSygnal固有の依存／署名鍵workaround。
- 導入コミット: `ab2940c` (`feat(sable): self-host web push with Sygnal for Sable PWA`)

### SygnalのPython依存をローカル定義・固定する

- 実装: `packages/sygnal/package.nix:8-102`, `packages/sygnal/pins.json`
- 理由:
  - `opentracing 2.4.0`と`jaeger-client 4.8.0`は、現在lockしているnixpkgsの`python312Packages`にないためローカルでパッケージ化する。
  - `pywebpush 2.0.0`を使う。2.3はSygnalの`HttpDelayedRequest`に存在しない`response.headers`へアクセスする。
  - `Twisted 24.7.0`を使う。Twisted 26ではSygnalの`_AgentBase`を使うApple Web Pushがstallし、Push Gatewayが504を返す。
- 撤去条件: nixpkgsへのpackage追加、またはSygnal・依存package側の互換性問題の解消後に、個別定義なしでbuildとpush配信を確認できたとき。
- 導入コミット:
  - `ab2940c` (`feat(sable): self-host web push with Sygnal for Sable PWA`) — `opentracing`、`jaeger-client`のローカル定義
  - `357aa01` (`fix(sygnal): pin pywebpush to upstream lock version`) — `pywebpush`
  - `bd91209` (`fix: pinned Twisted 24.7.0`) — `Twisted`

### Sygnalの依存バージョン制約を緩和する

- 実装: `packages/sygnal/package.nix:117-121`
- 理由: upstreamの`pyproject.toml`の上限では、nixpkgsにある新しい依存packageを利用できない。
- 対応: `aioapns`を`<4.0`から`<5.0`、`prometheus_client`を`<0.8`から`<1.0`へ書き換える。
- 撤去条件: upstreamが利用中のバージョンを許容するか、制約を書き換えずに依存を解決できたとき。
- 導入コミット: `ab2940c` (`feat(sable): self-host web push with Sygnal for Sable PWA`)

### Sygnalの期限切れ署名鍵証明書を限定的に許容する

- 実装: `scripts/update-sygnal.sh:50-61`
- 理由: Sygnal v0.17.0の署名に使われたsubkeyは現在期限切れで、更新済みcertificateも見つかっていない。
- 対応: pinned keyの`EXPKEYSIG`と`KEYEXPIRED` noticeを許容する。期限切れ署名`EXPSIG`、失効鍵`REVKEYSIG`、primary fingerprint不一致は引き続き拒否する。
- 撤去条件: upstreamから検証可能な更新済みcertificateまたは新しい有効な署名が提供されたとき。
- 導入コミット: `ea694dc` (`refactor: update scripts`)

### Tuwunelのremote mediaを7日で削除する

- 実装: `guests/tuwunel/configuration.nix:87-91`
- 理由: 必要なmedia管理機能が不足しているため、無制限な蓄積を避ける。
- 対応: signal処理でdatabase backupに加えて`media delete-range 7d --older-than`を実行する。
- 撤去・再検討条件: Tuwunel issue 334、367、474などの関連機能が実装されたとき。
- 導入コミット: `3003cc4` (`feat(tuwunel): prune remote media`)

## NixOS・build toolへの適応

### `CONFIG_MODULES=n`のhost kernelをNixOSで使う

- 実装:
  - `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/kernel.nix:20-28`
  - `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/configuration.nix:21-27`
  - `modules/host/default.nix:186-187`
- 理由: loadable module supportを無効にしても、NixOSのinitrd構築とsystemdはbuilt-in module metadataを要求する。また、NixOSとIncusの既定設定にはmoduleをloadする前提がある。
- 対応:
  - `modules.builtin`と`modules.builtin.modinfo`をinstallし、空の`modules.order`を作って`depmod`する。
  - `boot.initrd.allowMissingModules = true`にする。
  - container専用hostでは不要な`vhost_vsock`要求を無効化する。
  - modprobe設定の生成を無効化する。
- 撤去条件: `CONFIG_MODULES=n`のkernelをこれらの補助設定なしでNixOSが扱えるようになったとき、またはloadable moduleを再度有効化したとき。
- 導入コミット:
  - `f5feabc` (`add ovhcloud`) — metadata生成、initrdとIncus向け設定
  - `b94b9dc` (`fix(host): disable modprobe setup for module disabled kernels`) — modprobe設定の無効化

### Clang 21で利用できないkmalloc hardeningを代替する

- 実装: `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/kernel.nix:150-151`および各`kernel.config`
- 理由: NixOS kernelのbuildに使うClang 21では、Linux 7.2で追加された`KMALLOC_PARTITION_TYPED`を利用できない。
- 対応: assertionとkernel configで`KMALLOC_PARTITION_RANDOM`を要求する。
- 撤去条件: 使用toolchainが`KMALLOC_PARTITION_TYPED`をサポートしたとき。
- 導入コミット: `c2184d1` (`update-flake and kernel`)

### Incus guestの再起動先を現在のNixOS generationへ更新する

- 実装: `modules/guest/default.nix:33-36`
- 理由: `boot.isContainer`だけでは、構成切り替え後の`/sbin/init`が現在generationへ更新されず、再起動時に古いgenerationへ戻る。
- 対応: `lxc-container.nix`のうちinit symlink更新だけを`system.build.installBootLoader`として実装する。
- 撤去条件: NixOSのcontainer切り替え処理がIncus guestでも現在generationのinitを更新するようになったとき。
- 導入コミット: `ace68a2` (`fix(guest): update LXC init so rebootsuse the current generation`)

### eturnal wrapperを`postFixup`で作る

- 実装: `packages/eturnal/package.nix:55-74`
- 理由: `rebar3Relx`が`postInstall`を上書きする。
- 対応: runtime `PATH`と`RUNTIME_DIRECTORY`を設定するwrapperを`postFixup`で作る。
- 撤去条件: `rebar3Relx`で`postInstall`を安全に追加できるようになるか、wrapperが不要になったとき。
- 導入コミット: `3bd3224` (`feat(rtc): replace coturn with eturnal`)

### SOPSで生成するKnot設定を起動時に検証する

- 実装: `guests/knot/configuration.nix:256-259`
- 理由: `keyFiles`がruntime SOPS templateを含むため、Nix build sandbox内では完全な設定を検証できない。
- 対応: `ExecStartPre`で`knotc ... conf-check`を実行する。
- 撤去条件: secretを公開せずbuild時に完全な設定検証ができるようになったとき。
- 導入コミット: `58372fb` (`feat: use DNSSEC and migrate dns server to Knot`)

## Incus・provider・networkへの適応

### Tuwunelからnginxへのhairpin NATを手動設定する

- 実装: `hosts/aracha-ovh/configuration.nix:86-103`
- 理由: Incusはbridge-originated trafficをpublic address向けforwardへDNATせず、DNATだけでは戻り経路も非対称になる。TuwunelではSSRF防止のためpublic Matrix/Push URLを維持する必要がある。
- 対応: 対象Tuwunel guestからnginxへのHTTPS通信だけをDNATし、同じflowだけmasqueradeする。共有HTTPS forward全体はSNATせず、外部client IPを維持する。
- 撤去条件: Incus側でhairpin NATが提供されるか、public URLを経由しない安全な構成へ変更したとき。
- 導入コミット:
  - `59058fc` (`fix: add scoped hairpin NAT for Sygnal`)
  - `d1e107c` (`fix: DNAT Tuwunel push hairpin traffic`)
  - `2fadac5` (`feat: add guest matrix call`) — guest Tuwunelも対象へ追加

### Incus providerのACL表現差を吸収する

- 実装: `tofu/acls.tf:7-35`
- 理由: providerは空のrule setを`null`として読み戻す。また、bridge ACLのegressではnftablesの`reject`を利用できない。
- 対応: 空ACLは最初から`null`にし、egress拒否には`drop`を使う。
- 撤去条件: providerの空配列round-tripとbridge ACLの`reject`が利用可能になったとき。
- 導入コミット: `9f7cace` (`fix(tofu): handle bridge ACL rule behavior`)

### Incus bridge生成後にjournal receiverを起動する

- 実装: `modules/host/default.nix:102-114`
- 理由: Incusは`incusbr0`を非同期に作るため、`incus.service`の起動順だけでは`BindToDevice=incusbr0`が失敗することがある。
- 対応: journal receiver socketを`incusbr0.device`へ依存させ、bridge消失時も停止する。
- 撤去条件: Incus serviceがbridgeの利用可能化まで同期するか、receiverがbridgeへbindしない構成になったとき。
- 導入コミット: `076ac1b` (`fix: start journal receiver after Incus bridge`)

### 月次R2 backupでbucket確認を省略する

- 実装:
  - `guests/knot/configuration.nix:309-316`
  - `guests/prosody/configuration.nix:395-405`
  - `guests/tuwunel/configuration.nix:253-262`
- 理由: archive用credentialで不要なbucket作成・存在確認を行わせず、既存bucketへのobject uploadだけを行う。
- 対応: `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`と`--config /dev/null`を指定して`rclone rcat`を実行する。
- 撤去条件: rclone/R2の確認処理が権限と運用方針に適合するようになったとき。
- 導入コミット: `d15383e` (`fix: skip R2 bucket creation checks in monthly backups`)

## Prosodyへのdownstream workaround

### `http_external_url`を明示する

- 実装: `guests/prosody/configuration.nix:145-148,184-186`
- 理由: `net_multiplex`が443を所有し、Prosodyのport managerからactiveなHTTPS serviceが見えないため、`module:http_url()`が`http://disabled.invalid/`を返す。これによりinvite pageのasset URLとfile upload URLが壊れる。
- 対応: main virtual hostとHTTP file shareにpublic HTTPS URLを明示する。
- 撤去条件: `net_multiplex`使用時もProsodyが正しいexternal URLを解決できるようになったとき。
- 導入コミット: `ea8852c` (`fix(prosody): set http_external_url to fix disabled.invalid URLs`)

### async-runner fallbackへHSTSを追加する

- 実装: `guests/prosody/configuration.nix:99-104`
- 理由: Prosody HTTP serverのasync-runner fallbackは固定されたheader setを書き出し、`mod_http_hsts`が設定したheaderを通常経路と同様にはserializeしない。
- 対応: upstreamの`server.lua`へ`Strict-Transport-Security`のserialize処理を直接追加する。
- 撤去条件: upstream fallbackがresponse headerを一般的にserializeするようになったとき。
- 導入コミット: `3639cb6` (`feat: apply HSTS policy to all HTTPS responses`)

### S2S direct TLSを443で広告しない

- 実装: `guests/knot/zones/odarah.org.zone:37-41`, `guests/prosody/configuration.nix:223-225`
- 理由: `net_multiplex`は443のS2S接続でpeer certificateを要求せず、secure S2S authenticationが失敗する。
- 対応: `_xmpps-server`の443 SRV recordを置かず、direct TLSは5270で広告する。443のclient direct TLSは維持する。
- 撤去条件: `net_multiplex`経由の443でもS2S peer certificate検証が正しく動くようになったとき。
- 導入コミット: `b470ae7` (`fix(xmpp): avoid broken s2s TLS multiplexing on port 443`)

## Web clientへのdownstream workaround

### Cinnyのruntime drag styleをpatchする

- 実装: `guests/nginx/configuration.nix:282-287`
- 理由: Cinnyがdrag中に`CSSStyleSheet.insertRule()`でstyleを注入し、main pageのstrict CSPと両立しない。
- 対応: 対象bundleのSHA-256を検証してから、style設定を`style.textContent`へ書き換える。
- 撤去条件: Cinny upstreamがstrict CSPと両立するstyle処理へ変更したとき。Cinny更新時はbundle path、hash、置換対象を再確認する。
- 導入コミット: `93c7dff` (`feat: harden Cinny style CSP`)

### 埋め込みElement CallだけCSPを緩和する

- 実装: `guests/nginx/configuration.nix:891-898`
- 理由: Element Callが動的なstyle elementとstyle attributeを生成するため、Cinny main pageのstrict style policyでは動かない。
- 対応: `/public/element-call/`だけ別のCSPへ差し替え、inline styleを許可する。
- 撤去条件: Element Callがinline styleなしで動作するようになったとき。
- 導入コミット: `93c7dff` (`feat: harden Cinny style CSP`)

### `writeNginxConfig`が壊すregex量指定子を展開する

- 実装: `guests/nginx/configuration.nix:616-620`
- 理由: `writeNginxConfig`が正規表現の`{7,}`をmangleする。
- 対応: 7個の`[0-9a-f]`と末尾の`[0-9a-f]*`へ展開して、content-hashed Element assetを判定する。
- 撤去条件: `writeNginxConfig`でbrace quantifierをそのまま記述できるようになったとき。
- 導入コミット: `26df541` (`feat: improve elements web client cache`)

## Security hardening上の互換性緩和

### LXCFSのためYama ptrace scopeを2にする

- 実装: `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/hardening.nix:30`
- 理由: `kernel.yama.ptrace_scope=3`ではLXCFSが動作しない。
- 対応: hostのptrace scopeを`2`にする。
- 撤去条件: LXCFSがscope 3で動くようになるか、LXCFSを使用しなくなったとき。
- 導入コミット: `8841122` (`fix: yama.ptrace_scope=2 for LXCFS`)

### Sygnalでは`MemoryDenyWriteExecute`を有効にしない

- 実装: `guests/sygnal/configuration.nix`の`sygnal.service` hardening設定
- 理由: Python CFFIが実行可能memoryを必要とし、`MemoryDenyWriteExecute=true`ではSygnalが動かない。
- 対応: 他のserviceで使用している`MemoryDenyWriteExecute`をSygnal serviceには設定しない。
- 撤去条件: Sygnalの依存が実行可能memoryを必要としなくなったとき。
- 導入コミット: `460f984` (`fix(sygnal): allow CFFI executable memory`)

### Incus guestのconsole-gettyを無効化する

- 実装: `modules/guest/default.nix:31-32`
- 理由: guestは`incus exec`で管理し、利用可能な`/dev/console`がない。
- 対応: `console-getty.service`を無効化する。
- 撤去条件: Incus guestへ利用可能なconsoleを提供する構成へ変更したとき。
- 導入コミット: `789f4db` (`fix: disable console-getty in incus guests`)

## 対象外のdownstream変更

次はlocal patchまたは特殊設定だが、現在はワークアラウンドではなくsecurity policy・機能追加として扱う。

- `guests/prosody/invites/patches/`のinvite page向けCSP、cache、Referrer-Policy追加
- Prosody HTTP logからquery stringを除くpatch
- ProsodyのOpenBSD client表示、独自invite HTML
- web clientのinline script外部化と一般的なCSP hardening

## 撤去済み

次のworkaroundはrevert済みであり、現行構成には含まれない。

- Tuwunel 1.9.1のdirect buildとthumbnail test無効化 — `2840052` (`Revert Tuwunel direct-build workarounds`)
- sops-nixをGo 1.26でbuildするoverride — `aeae177` (`Revert "feat: workaround, use Go 1.26 builder for sops-nix"`)
- Sygnalのsentry-sdk test無効化 — `c320b3a` (`Revert "fix: workaround, disable sentry-sdk test"`)
- Sygnalのpy-vapid test無効化 — `b3b27f8` (`Revert "fix: workaround, provide pytest and skip tests for py-vapid"`)
