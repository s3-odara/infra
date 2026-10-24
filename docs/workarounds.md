### Prosody 14まで`csi_battery_saver`を使う

- 実装: `guests/prosody/configuration.nix:44-64,204-208`
- 理由: 現在のProsodyでは、移行先にする予定の組み込み`csi_simple`をまだ使わない。
- 対応: Community Moduleの`csi_battery_saver`、`csi_muc_priorities`、`track_muc_joins`をpackageと`extraModules`へ追加する。
- 撤去条件: Prosody 14で`csi_simple`へ移行し、battery saverを削除できたとき。
- 導入コミット: `bc1342a` (`feat(prosody): save battery`)

### TuwunelがMSC4174を実装するまでSygnalを運用する

- 実装: `guests/sygnal/`, `packages/sygnal/`, `flake.nix`, nginx proxy
- 理由: 現在のTuwunelだけではMSC4174によるWeb Push配信を完結できない。
- 対応: 独立したSygnal guestをPush Gatewayとして運用し、Tuwunelから通知を転送する。
- 撤去条件: TuwunelがMSC4174を実装し、SygnalなしでWeb Pushできたとき。
- 導入コミット: `ab2940c` (`feat(sable): self-host web push with Sygnal for Sable PWA`)

### SygnalのPython依存をローカル定義・固定する

- 実装: `packages/sygnal/package.nix:8-102`, `packages/sygnal/pins.json`
- 理由: nixpkgsに`opentracing`と`jaeger-client`がなく、`pywebpush 2.3`とTwisted 26はSygnalのWeb Pushを壊す。
- 撤去条件: nixpkgsまたはupstreamで依存関係が解決し、Sygnalの配信を確認できたとき。
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
- 理由: Sygnal v0.17.0の署名subkeyが期限切れで、更新証明書がない。
- 対応: pinned keyの期限切れnoticeだけ許容し、期限切れ署名・失効鍵・fingerprint不一致は拒否する。
- 撤去条件: upstreamが有効な署名または更新証明書を提供したとき。
- 導入コミット: `ea694dc` (`refactor: update scripts`)

### Tuwunelのremote mediaを7日で削除する

- 実装: `guests/tuwunel/configuration.nix:87-91`
- 理由: 不要なremote mediaの蓄積を防ぐ。
- 対応: signal処理でbackup時に`media delete-range 7d --older-than`を実行する。
- 撤去条件: Tuwunelに同等のmedia管理機能が実装されたとき。
- 導入コミット: `3003cc4` (`feat(tuwunel): prune remote media`)

## NixOS・build toolへの適応

### update-flake時のkernel config生成で`preUnpack`を無効化する

- 実装: `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/kernel.nix`の`generatedKernelConfig`
- 理由: kernelの`preUnpack`が`$dev/lib/modules`を作るが、config生成用derivationには`dev` outputがない。
- 対応: config生成用derivationでは継承した`preUnpack` hookを空にする。
- 撤去条件: nixpkgsのhookがconfig-only derivationでも安全になったとき。
- 導入コミット: `a68578c` (`fix(kernel): skip inherited preUnpack for config generation`)

### `linuxManualConfig`へ`CONFIG_MODULES=n`を明示する

- 実装: `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/kernel.nix`
- 理由: `linuxManualConfig`が`CONFIG_MODULES=n`を解析せず、NixOSがmodule closureを作る。
- 対応: `config`へ`CONFIG_MODULES = "n"`を明示する。
- 撤去条件: `linuxManualConfig`が`n`も自動解析するようになったとき。
- 導入コミット: `8cdf376` (`refactor(kernel): expose CONFIG_MODULES=n to NixOS`)

### `CONFIG_MODULES=n`の空のmodule treeをaggregateModulesで扱う

- 実装: `modules/host/default.nix`
- 理由: nixpkgs `3a32588`が空の`/lib/modules`を作り、`depmod`へ`.`を渡して失敗する。
- 対応: module treeが空ならhost overlayで`depmod`をスキップする。
- 撤去条件: upstreamが空のmodule treeを扱えるようになったとき。
- 導入コミット: `d6fd809` (`fix: handle empty kernel module tree with CONFIG_MODULES=n`)

### Clang 21で利用できないkmalloc hardeningを代替する

- 実装: `hosts/{aracha-ovh,mecha-vultr,tencha-conoha}/kernel.nix:150-151`および各`kernel.config`
- 理由: Clang 21はLinux 7.2の`KMALLOC_PARTITION_TYPED`に未対応。
- 対応: kernel configとassertionで`KMALLOC_PARTITION_RANDOM`を要求する。
- 撤去条件: 使用toolchainが`KMALLOC_PARTITION_TYPED`をサポートしたとき。
- 導入コミット: `c2184d1` (`update-flake and kernel`)

### Incus guestの再起動先を現在のNixOS generationへ更新する

- 実装: `modules/guest/default.nix:33-36`
- 理由: Incus guestでは切り替え後も`/sbin/init`が古いgenerationを指す。
- 対応: `system.build.installBootLoader`でinit symlinkを更新する。
- 撤去条件: NixOSがIncus guestのinit symlinkも更新するようになったとき。
- 導入コミット: `ace68a2` (`fix(guest): update LXC init so rebootsuse the current generation`)

### eturnal wrapperを`postFixup`で作る

- 実装: `packages/eturnal/package.nix:55-74`
- 理由: `rebar3Relx`が`postInstall`を上書きする。
- 対応: runtime `PATH`と`RUNTIME_DIRECTORY`を設定するwrapperを`postFixup`で作る。
- 撤去条件: `postInstall`を追加できるか、wrapperが不要になったとき。
- 導入コミット: `3bd3224` (`feat(rtc): replace coturn with eturnal`)

### SOPSで生成するKnot設定を起動時に検証する

- 実装: `guests/knot/configuration.nix:256-259`
- 理由: runtime SOPS secretsがあり、build sandboxでは設定を完全に検証できない。
- 対応: 起動前に`knotc conf-check`を実行する。
- 撤去条件: secretsを公開せずbuild時に検証できるようになったとき。
- 導入コミット: `58372fb` (`feat: use DNSSEC and migrate dns server to Knot`)

### nixos-imagesのremoved initrd optionをsmallで回避する

- 実装: `flake.nix`の`kexecInstaller`と`modules/nixos-images/restore-remote-access.nix`
- 理由: nixpkgsで削除された`boot.initrd.systemd.enable`を、`nixos-images`がまだ設定する。
- 対応: upstream moduleを無効化し、remote-access serviceをローカル定義する。nixpkgsはpinしない。
- 撤去条件: upstream moduleが現行nixpkgsで評価・buildできるようになったとき。
- 導入コミット: `58e3735` (`fix: keep kexec installer working with unstable-small`)

### kexec installerでは不要なZFS supportを無効にする

- 実装: `flake.nix`の`kexecInstaller`
- 理由: installerに不要なZFS packageが入り、nixpkgsの`zfs-user-2.4.4` buildがpermission errorになる。
- 対応: installerのみZFS moduleを無効化する。hostのfilesystem設定は変更しない。
- 撤去条件: nixpkgsのZFS buildが直るか、ZFS hostを追加するとき。
- 導入コミット: `58e3735` (`fix: keep kexec installer working with unstable-small`)

## Incus・provider・networkへの適応

### Tuwunelからnginxへのhairpin NATを手動設定する

- 実装: `hosts/aracha-ovh/configuration.nix:86-103`
- 理由: Incusはbridge trafficをpublic forwardへDNATせず、TuwunelはSSRF対策上public URLsを使う。
- 対応: TuwunelからnginxへのHTTPSだけDNAT/masqueradeし、外部client IPは維持する。
- 撤去条件: Incusがhairpin NATを提供するか、public URL不要の構成に変えたとき。
- 導入コミット:
  - `59058fc` (`fix: add scoped hairpin NAT for Sygnal`)
  - `d1e107c` (`fix: DNAT Tuwunel push hairpin traffic`)
  - `2fadac5` (`feat: add guest matrix call`) — guest Tuwunelも対象へ追加

### Incus providerのACL表現差を吸収する

- 実装: `tofu/acls.tf:7-35`
- 理由: providerが空rule setを`null`に戻し、bridge ACLでは`reject`を使えない。
- 対応: 空ACLを`null`にし、egress拒否は`drop`にする。
- 撤去条件: providerが空配列を保持し、bridge ACLで`reject`を使えるとき。
- 導入コミット: `9f7cace` (`fix(tofu): handle bridge ACL rule behavior`)

### Incus bridge生成後にjournal receiverを起動する

- 実装: `modules/host/default.nix:102-114`
- 理由: Incusが`incusbr0`を非同期作成し、journal receiverのbindが失敗することがある。
- 対応: socketを`incusbr0.device`へ依存させ、bridge消失時も停止する。
- 撤去条件: Incusがbridge起動を同期するか、receiverがbind不要になったとき。
- 導入コミット: `076ac1b` (`fix: start journal receiver after Incus bridge`)

### 月次R2 backupでbucket確認を省略する

- 実装:
  - `guests/knot/configuration.nix:309-316`
  - `guests/prosody/configuration.nix:395-405`
  - `guests/tuwunel/configuration.nix:253-262`
- 理由: archive credentialでbucket作成・確認をさせず、既存bucketへuploadする。
- 対応: `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true`と`--config /dev/null`を指定して`rclone rcat`を実行する。
- 撤去条件: rclone/R2の確認処理が権限方針に合うようになったとき。
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

次のworkaroundは現行構成から撤去済み。

- Sygnal closure内のAnyIOテスト無効化 — nixpkgs更新でAnyIO 4.15.1のテストが通ることを確認
- Tuwunel 1.9.1のdirect buildとthumbnail test無効化 — `2840052` (`Revert Tuwunel direct-build workarounds`)
- sops-nixをGo 1.26でbuildするoverride — `aeae177` (`Revert "feat: workaround, use Go 1.26 builder for sops-nix"`)
- Sygnalのsentry-sdk test無効化 — `c320b3a` (`Revert "fix: workaround, disable sentry-sdk test"`)
- Sygnalのpy-vapid test無効化 — `b3b27f8` (`Revert "fix: workaround, provide pytest and skip tests for py-vapid"`)
- Incus IPv4 filteringを使わない — `a7f87df` (`fix(incus): re-enable ipv4 filtering`)
