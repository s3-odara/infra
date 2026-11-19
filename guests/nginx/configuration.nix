{
  config,
  configurationName,
  lib,
  pkgs,
  sable-unwrapped,
  ...
}:

let
  odarahHost = "odarah.org";
  matrixHost = "matrix.odarah.org";
  cinnyHost = "cinny.matrix.odarah.org";
  elementHost = "element.matrix.odarah.org";
  guestMatrixHost = "guest.matrix.odarah.org";
  rtcHost = "rtc.matrix.odarah.org";
  sableHost = "sable.matrix.odarah.org";
  pushHost = "push.matrix.odarah.org";
  davHost = "dav.odarah.org";
  acmeDnsEnvironment = pkgs.writeText "acme-rfc2136.env" ''
    DNSUPDATE_NAMESERVER=10.77.3.11:53
    DNSUPDATE_TSIG_KEY=nginx.
    DNSUPDATE_TSIG_ALGORITHM=hmac-sha256.
    DNSUPDATE_TTL=60
    DNSUPDATE_SEQUENCE_INTERVAL=2
    DNSUPDATE_ZONES=_acme-challenge.odarah.org.
  '';
  prosodyAddress = "10.77.3.10";
  tuwunelAddress = "10.77.3.14";
  guestTuwunelAddress = "10.77.3.17";
  rtcAddress = "10.77.3.15";
  sygnalAddress = "10.77.3.16";
  radicaleAddress = "10.77.3.18";
  pushClientConfig = builtins.fromJSON (builtins.readFile ../../packages/sygnal/client-config.json);
  oidcAccountCss = ./tuwunel-oidc.css;
  webClientHtml = pkgs.callPackage ../../packages/web-client-html/package.nix { };
  matrixLandingRoot = pkgs.linkFarm "matrix-landing-root" [
    {
      name = "index.html";
      path = ./matrix-landing.html;
    }
  ];
  odarahLandingRoot = pkgs.linkFarm "odarah-landing-root" [
    {
      name = "index.html";
      path = ./odarah-landing.html;
    }
  ];

  # Fixed styles injected by react-colorful and the patched drag-and-drop fix.
  # PDF.js only injects a font stylesheet when document.fonts is unavailable;
  # browsers supporting the CSP Level 3 directives below use its FontFace path.
  cinnyStyleHashes = "'sha256-I2px+fnpbN4E5+Djrj7aoTIyq9yyREkuVl19f4Sye9A=' 'sha256-gE6f9B7Di/6xvPsuFkoYXxNapPKVLAmRBvP73rpQ9+Y='";
  sableCsp = {
    beforeHashes = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'none'; script-src 'self' 'wasm-unsafe-eval'";
    afterHashes = "; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self'";
  };
  cinnyCsp = {
    beforeHashes = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'; script-src 'self' 'wasm-unsafe-eval'";
    afterHashes = "; script-src-attr 'none'; style-src 'self' ${cinnyStyleHashes}; style-src-elem 'self' ${cinnyStyleHashes}; style-src-attr 'none'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self'";
  };
  cinnyCallCsp = {
    beforeHashes = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'; script-src 'self' 'wasm-unsafe-eval'";
    afterHashes = "; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self'";
  };
  elementCsp = {
    beforeHashes = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'; script-src 'self' 'wasm-unsafe-eval'";
    afterHashes = "; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self' blob:";
  };
  elementCallCsp = {
    beforeHashes = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'none'; script-src 'self' 'wasm-unsafe-eval'";
    afterHashes = "; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${guestMatrixHost}; media-src 'self' blob: https://${guestMatrixHost}; connect-src 'self' https://${guestMatrixHost} wss://${guestMatrixHost} https://${rtcHost} wss://${rtcHost}";
  };

  # Hash the served document(s), keeping hashes inside the script-src directive.
  writeCsp =
    {
      html,
      output,
      policy,
    }:
    ''
      hashes="$(web-client-html hashes ${html})"
      printf '%s\n' "${policy.beforeHashes} $hashes${policy.afterHashes}" > ${output}
    '';

  precompressStaticAssets = pkgs.writeShellScript "precompress-static-assets" ''
    set -euo pipefail

    ${pkgs.findutils}/bin/find "$1" -type f -size +256c \
      \( -iname '*.css' -o -iname '*.csv' -o -iname '*.html' -o -iname '*.js' \
      -o -iname '*.json' -o -iname '*.map' -o -iname '*.mjs' -o -iname '*.otf' \
      -o -iname '*.svg' -o -iname '*.ttf' -o -iname '*.txt' -o -iname '*.vtt' \
      -o -iname '*.wasm' -o -iname '*.webmanifest' -o -iname '*.xml' \) \
      -print0 | while IFS= read -r -d "" file; do
        [[ -e "$file.gz" ]] || ${pkgs.gzip}/bin/gzip -9 -n -k "$file"
        [[ -e "$file.br" ]] || ${pkgs.brotli}/bin/brotli -q 9 -k "$file"
      done
  '';

  # Match the dictionary.rs pin; keep the lazy fetch on the Sable origin.
  sableJiebaSource = "https://raw.githubusercontent.com/messense/jieba-rs/9faccca490d8e797a14d6daffed2a96de9629df7";
  sableDictionaryHash = "139519822fe8ab9e10d9d07e68ea0451045380aedaf54ecc51e2a28c6b42a13f";
  sableDictionaryPath = "assets/jieba-${sableDictionaryHash}.txt";
  sableDictionary = pkgs.fetchurl {
    url = "${sableJiebaSource}/jieba/src/data/dict.txt";
    sha256 = sableDictionaryHash;
  };
  sableDictionaryLicense = pkgs.fetchurl {
    url = "${sableJiebaSource}/LICENSE";
    hash = "sha256-kiV8jRx6BZ+gJyCzT84BdXSpkL7RTO6PVlWX9Pv7HxM=";
  };
  sableWithLocalDictionary = sable-unwrapped.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      dictionary=crates/sable-core/src/search/dictionary.rs
      grep -Fxq 'const SHA256: &str = "${sableDictionaryHash}";' "$dictionary"
      substituteInPlace "$dictionary" \
        --replace-fail '"${sableDictionary.url}"' '"https://${sableHost}/${sableDictionaryPath}"'
    '';
  });

  sable =
    pkgs.runCommand "sable-${sableWithLocalDictionary.version}-odarah"
      {
        nativeBuildInputs = [ pkgs.diffutils ];
        outputs = [
          "out"
          "webDiff"
        ];
      }
      ''
        cp -R ${sableWithLocalDictionary} "$out"
        chmod -R u+w "$out"
        # Add after the web build so the service worker does not precache it.
        install -Dm644 ${sableDictionary} "$out/${sableDictionaryPath}"
        install -m644 ${sableDictionaryLicense} "$out/assets/jieba-LICENSE.txt"
        mkdir -p "$webDiff"
        for file in index.html 404.html service-worker.js manifest.webmanifest; do
          test -s "$out/$file"
        done
        test -d "$out/_app/immutable"
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        cat > "$out/config.json" <<'JSON'
        {
          "branding": { "appName": "Sable" },
          "defaultHomeserver": 0,
          "homeserverList": ["${matrixHost}"],
          "allowCustomHomeservers": false,
          "calls": { "livekitServiceUrl": "https://${rtcHost}" },
          "disableAccountSwitcher": false,
          "hideUsernamePasswordFields": false,
          "pushNotificationDetails": {
            "pushNotifyUrl": "https://${pushHost}/_matrix/push/v1/notify",
            "vapidPublicKey": "${pushClientConfig.vapidPublicKey}",
            "webPushAppID": "${pushClientConfig.webPushAppID}"
          },
          "featuredCommunities": { "servers": [] }
        }
        JSON
        diff -u --label upstream/config.json --label local/config.json \
          ${sableWithLocalDictionary}/config.json "$out/config.json" > "$webDiff/sable-config.diff" || test "$?" -eq 1
        # Deployment headers are owned by this IaC, not the upstream files.
        rm "$out/csp.caddy" "$out/_headers"
        ${precompressStaticAssets} "$out"
      '';

  cinny =
    pkgs.runCommand "cinny-${pkgs.cinny-unwrapped.version}-odarah"
      {
        nativeBuildInputs = [ pkgs.diffutils ];
        outputs = [
          "out"
          "webDiff"
        ];
      }
      ''
        cp -R ${pkgs.cinny-unwrapped} "$out"
        chmod -R u+w "$out"
        mkdir -p "$webDiff"
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        # Keep the separate gate for Cinny's runtime-injected drag style.
        printf '%s  %s\n' 2b609a83eeb53ee19c83e48bca5687b6606161f7f6972f6b6babb9a932acd407 "$out/assets/index-DWIvG3QT.js" | ${pkgs.coreutils}/bin/sha256sum -c -
        substituteInPlace "$out/assets/index-DWIvG3QT.js" \
          --replace-fail \
            'document.head.appendChild(e),(t=e.sheet)===null||t===void 0||t.insertRule("* { pointer-events: none !important; }")' \
            'e.textContent="* { pointer-events: none !important; }",document.head.appendChild(e)'
        cat > "$out/config.json" <<'JSON'
        {
          "defaultHomeserver": 0,
          "homeserverList": ["matrix.odarah.org"],
          "allowCustomHomeservers": false,
          "featuredCommunities": { "openAsDefault": false, "spaces": [], "rooms": [], "servers": [] },
          "hashRouter": { "enabled": false, "basename": "/" }
        }
        JSON
        diff -u --label upstream/config.json --label local/config.json \
          ${pkgs.cinny-unwrapped}/config.json "$out/config.json" > "$webDiff/cinny-config.diff" || test "$?" -eq 1
        ${precompressStaticAssets} "$out"
      '';

  elementConfig = {
    default_server_config."m.homeserver" = {
      base_url = "https://${matrixHost}";
      server_name = matrixHost;
    };
    disable_custom_urls = true;
    disable_guests = true;
    disable_3pid_login = true;
    integrations_ui_url = null;
    integrations_rest_url = null;
    integrations_widgets_urls = null;
    room_directory.servers = [ ];
    map_style_url = null;
    element_call = {
      disable = false;
      use_exclusively = true;
      guest_spa_url = "https://${guestMatrixHost}";
    };
  };
  elementConfigFile = pkgs.writeText "element-config.json" (builtins.toJSON elementConfig);
  elementCallConfig = {
    default_server_config."m.homeserver" = {
      base_url = "https://${guestMatrixHost}";
      server_name = guestMatrixHost;
    };
    livekit.livekit_service_url = "https://${rtcHost}";
  };
  elementCallConfigFile = pkgs.writeText "element-call-config.json" (
    builtins.toJSON elementCallConfig
  );
  elementCall = pkgs.runCommand "element-call-${pkgs.element-call.version}-odarah" { } ''
    mkdir -p "$out"
    cp -R ${pkgs.element-call}/. "$out/"
    chmod -R u+w "$out"
    cp ${elementCallConfigFile} "$out/config.json"
    cp ${./element-call-guest-only.css} "$out/guest-only.css"
    substituteInPlace "$out/index.html" \
      --replace-fail '</head>' '<link rel="stylesheet" href="/guest-only.css"></head>'
    ${precompressStaticAssets} "$out"
  '';
  element =
    pkgs.runCommand "element-web-${pkgs.element-web-unwrapped.version}-odarah"
      {
        nativeBuildInputs = [
          webClientHtml
          pkgs.diffutils
        ];
        outputs = [
          "out"
          "webDiff"
        ];
      }
      ''
        mkdir -p "$out"
        cp -R ${pkgs.element-web-unwrapped}/. "$out/"
        chmod -R u+w "$out"
        mkdir -p "$webDiff"
        web-client-html remove-meta-csp "$out/index.html"
        diff -u --label before/index.html --label after/index.html \
          ${pkgs.element-web-unwrapped}/index.html "$out/index.html" > "$webDiff/element-index.html.diff" || test "$?" -eq 1
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        cp ${elementConfigFile} "$out/config.json"
        diff -u --label upstream/config.json --label local/config.json \
          ${pkgs.element-web-unwrapped}/config.json "$out/config.json" > "$webDiff/element-config.diff" || test "$?" -eq 1
        ${precompressStaticAssets} "$out"
      '';

  caddyPackage = pkgs.caddy.withPlugins {
    plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.0" ];
    hash = "sha256-d4VdlHHF0cqzknO7eS+l9uI2fpCfTQWEirx/5PMHzLk=";
  };
  # Caddy and the CI review output use these exact policy values.
  cspPolicies = pkgs.runCommand "web-client-csp" { nativeBuildInputs = [ webClientHtml ]; } ''
    mkdir -p "$out"
    printf '%s\n' "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" > "$out/landing.csp"
    # Include every generated SvelteKit page, including the SPA fallback.
    ${writeCsp {
      html = "${sable}";
      output = ''"$out/sable.csp"'';
      policy = sableCsp;
    }}
    ${writeCsp {
      html = "${cinny}/index.html";
      output = ''"$out/cinny.csp"'';
      policy = cinnyCsp;
    }}
    ${writeCsp {
      html = "${cinny}/public/element-call/index.html";
      output = ''"$out/cinny-call.csp"'';
      policy = cinnyCallCsp;
    }}
    ${writeCsp {
      html = "${element}/index.html";
      output = ''"$out/element.csp"'';
      policy = elementCsp;
    }}
    ${writeCsp {
      html = "${element}/widgets/element-call/index.html";
      output = ''"$out/element-embedded-call.csp"'';
      policy = elementCsp;
    }}
    ${writeCsp {
      html = "${elementCall}/index.html";
      output = ''"$out/element-call.csp"'';
      policy = elementCallCsp;
    }}
  '';
  caddyConfig = pkgs.runCommand "nginx-Caddyfile" { } ''
    substitute ${./Caddyfile} "$out" \
      --subst-var-by ODARAH_LANDING_ROOT ${lib.escapeShellArg (toString odarahLandingRoot)} \
      --subst-var-by MATRIX_LANDING_ROOT ${lib.escapeShellArg (toString matrixLandingRoot)} \
      --subst-var-by ELEMENT_CALL_ROOT ${lib.escapeShellArg (toString elementCall)} \
      --subst-var-by CINNY_ROOT ${lib.escapeShellArg (toString cinny)} \
      --subst-var-by ELEMENT_ROOT ${lib.escapeShellArg (toString element)} \
      --subst-var-by SABLE_ROOT ${lib.escapeShellArg (toString sable)} \
      --subst-var-by OIDC_ROOT ${lib.escapeShellArg (toString (builtins.dirOf oidcAccountCss))} \
      --subst-var-by LANDING_CSP "$(<${cspPolicies}/landing.csp)" \
      --subst-var-by SABLE_CSP "$(<${cspPolicies}/sable.csp)" \
      --subst-var-by CINNY_CSP "$(<${cspPolicies}/cinny.csp)" \
      --subst-var-by CINNY_CALL_CSP "$(<${cspPolicies}/cinny-call.csp)" \
      --subst-var-by ELEMENT_CSP "$(<${cspPolicies}/element.csp)" \
      --subst-var-by ELEMENT_EMBEDDED_CALL_CSP "$(<${cspPolicies}/element-embedded-call.csp)" \
      --subst-var-by ELEMENT_CALL_CSP "$(<${cspPolicies}/element-call.csp)"
  '';
  caddyRuntimeConfig =
    pkgs.runCommand "caddy-runtime.json"
      {
        nativeBuildInputs = [
          caddyPackage
          pkgs.jq
        ];
      }
      ''
        caddy adapt --config ${caddyConfig} --adapter caddyfile > adapted.json
        # Use the same routes and rate-limit buckets for both transports.
        # Only the loopback TCP listener uses PROXY protocol. Nginx owns TCP/443.
        jq -e '
          .apps.http.servers.web |= (
            if .listen != ["127.0.0.1:8447"] or .protocols != ["h1", "h2"] then
              error("unexpected Caddy Web listener")
            else
              .listen += ["0.0.0.0:443"]
              | .listen_protocols = [.protocols, ["h3"]]
              | .allow_0rtt = false
            end
          )
        ' adapted.json > "$out"
      '';
in
{
  # Also expose the processed Sable site for focused update/build checks.
  system.build.sable = sable;
  system.build.caddyConfig = caddyConfig;
  system.build.caddyRuntimeConfig = caddyRuntimeConfig;

  # CI prints generated CSPs and config/HTML diffs without serving the reports.
  system.build.webClientDiffs = pkgs.linkFarm "web-client-html-diffs" [
    {
      name = "csp";
      path = cspPolicies;
    }
    {
      name = "sable";
      path = sable.webDiff;
    }
    {
      name = "cinny";
      path = cinny.webDiff;
    }
    {
      name = "element";
      path = element.webDiff;
    }
  ];

  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs.${matrixHost} = {
      webroot = null;
      dnsProvider = "rfc2136";
      environmentFile = acmeDnsEnvironment;
      credentialFiles.DNSUPDATE_TSIG_SECRET_FILE = config.sops.secrets.nginx_tsig_secret.path;
      extraDomainNames = [
        odarahHost
        cinnyHost
        elementHost
        guestMatrixHost
        rtcHost
        sableHost
        pushHost
        davHost
      ];
      profile = "shortlived";
      # Dropping --reuse-key changes the certificate cache, not the CAA-bound account.
      group = "caddy";
      reloadServices = [ "caddy.service" ];
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
    };
  };

  systemd.timers."acme-renew-${matrixHost}".timerConfig.AccuracySec = lib.mkForce "1s";
  systemd.services."acme-order-renew-${matrixHost}" = {
    serviceConfig = {
      Restart = "on-failure";
      RestartSteps = 4;
      RestartMaxDelaySec = "6h";
      LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
      ExecStopPost = pkgs.writeShellScript "notify-acme-failure" ''
        if [ "$SERVICE_RESULT" != "success" ]; then
          topic="$(<"$CREDENTIALS_DIRECTORY/ntfy-topic")"
          ${pkgs.curl}/bin/curl \
            --silent \
            --show-error \
            --fail \
            --output /dev/null \
            --max-time 15 \
            --header "Priority: 5" \
            --header "Tags: warning" \
            --data-binary 'nginx のTLS証明書更新が失敗しました。' \
            "https://ntfy.sh/$topic" || true
        fi
      '';
    };

    unitConfig.StartLimitIntervalSec = 0;
  };

  networking.nftables = {
    enable = true;
    flushRuleset = false;
    tables.nginx-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ip daddr 127.0.0.1 tcp dport 8447 meta skuid != "${config.services.nginx.user}" counter reject
          meta skuid "${config.services.nginx.user}" jump nginx_egress
          meta skuid "caddy" jump caddy_egress
        }

        chain nginx_egress {
          # Preserve responses to TCP stream clients without granting arbitrary
          # established outbound connections to the Nginx worker UID.
          ct direction reply counter accept
          ip daddr 127.0.0.1 tcp dport { 8447, 9444, 9445, 9446 } counter accept
          ip daddr ${prosodyAddress} tcp dport 443 counter accept
          ip daddr ${rtcAddress} tcp dport 5349 counter accept
          counter reject with icmpx type admin-prohibited
        }

        chain caddy_egress {
          ct direction reply counter accept
          ip daddr { ${tuwunelAddress}, ${guestTuwunelAddress} } tcp dport 8008 counter accept
          ip daddr ${rtcAddress} tcp dport { 7880, 8081 } counter accept
          ip daddr ${sygnalAddress} tcp dport 5000 counter accept
          ip daddr ${radicaleAddress} tcp dport 5232 counter accept
          counter reject with icmpx type admin-prohibited
        }
      '';
    };
    # Rewrite only the build-check copy, not the installed username rules.
    preCheckRuleset = ''
      substituteInPlace ruleset.conf \
        --replace-fail 'meta skuid != "${config.services.nginx.user}"' 'meta skuid != 65534' \
        --replace-fail 'meta skuid "${config.services.nginx.user}"' 'meta skuid 65534' \
        --replace-fail 'meta skuid "caddy"' 'meta skuid 65534'
    '';
  };

  systemd.services.nginx = {
    bindsTo = [ "nftables.service" ];
    after = [ "nftables.service" ];
    serviceConfig.InaccessiblePaths = [
      "-/var/lib/acme"
      "-/run/secrets"
      "-/run/caddy"
      "-/var/log/caddy"
    ];
  };

  services.caddy = {
    enable = true;
    package = caddyPackage;
    configFile = caddyRuntimeConfig;
    adapter = null;
    enableReload = true;
  };

  systemd.services.caddy = {
    bindsTo = [ "nftables.service" ];
    requires = [ "acme-${matrixHost}.service" ];
    after = [
      "nftables.service"
      "acme-${matrixHost}.service"
      "nginx.service"
    ];
    serviceConfig = {
      RuntimeDirectory = "caddy";
      RuntimeDirectoryMode = "0700";
      LogsDirectoryMode = "0750";
      UMask = "0027";
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      ProtectSystem = "strict";
      ProtectProc = "invisible";
      InaccessiblePaths = [ "-/run/secrets" ];
    };
  };

  services.nginx = {
    enable = true;
    # The guest has one CPU of quota; extra workers do not add CPU capacity.
    workerProcesses = 1;
    # TLS passes through one stream proxy before Caddy's HTTP listener, so
    # internal connections consume worker slots during scan bursts.
    eventsConfig = ''
      worker_connections 4096;
    '';
    appendConfig = ''
      worker_rlimit_nofile 16384;
    '';
    # Forward ciphertext; only Caddy and the XMPP/TURN backends terminate TLS.
    # The intermediate listeners strip PROXY protocol for XMPP/TURN.
    streamConfig = ''
      set_real_ip_from 127.0.0.1;

      map $ssl_preread_server_name $tls_dispatch {
        ${odarahHost} 127.0.0.1:8447;
        ${matrixHost} 127.0.0.1:8447;
        ${cinnyHost} 127.0.0.1:8447;
        ${elementHost} 127.0.0.1:8447;
        ${guestMatrixHost} 127.0.0.1:8447;
        ${rtcHost} 127.0.0.1:8447;
        ${sableHost} 127.0.0.1:8447;
        ${pushHost} 127.0.0.1:8447;
        ${davHost} 127.0.0.1:8447;
        turn.odarah.org 127.0.0.1:9446;
        xmpp.odarah.org 127.0.0.1:9444;
        conference.xmpp.odarah.org 127.0.0.1:9444;
        share.xmpp.odarah.org 127.0.0.1:9444;
        default 127.0.0.1:9445;
      }

      server {
        listen 0.0.0.0:443;
        ssl_preread on;
        proxy_protocol on;
        proxy_pass $tls_dispatch;
      }

      server {
        listen 127.0.0.1:9444 proxy_protocol;
        proxy_pass ${prosodyAddress}:443;
      }

      server {
        listen 127.0.0.1:9445 proxy_protocol;
        return "";
      }

      server {
        listen 127.0.0.1:9446 proxy_protocol;
        proxy_pass ${rtcAddress}:5349;
      }
    '';
  };

  sops.secrets = {
    nginx_tsig_secret = { };
    ntfy_topic = { };
  };

  system.stateVersion = "26.05";
}
