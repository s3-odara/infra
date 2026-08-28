{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  odarahHost = "odarah.org";
  matrixHost = "matrix.odarah.org";
  cinnyHost = "cinny.matrix.odarah.org";
  elementHost = "element.matrix.odarah.org";
  rtcHost = "rtc.matrix.odarah.org";
  sableHost = "sable.matrix.odarah.org";
  prosodyAddress = "10.77.3.10";
  tuwunelAddress = "10.77.3.14";
  rtcAddress = "10.77.3.15";
  oidcAccountCss = ./tuwunel-oidc.css;
  cspInline = ./csp-inline;
  webClientPatches = ./web-client-patches;
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

  landingSecurityHeaders = ''
    add_header Content-Security-Policy "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;
    add_header Permissions-Policy "accelerometer=(), ambient-light-sensor=(), autoplay=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
  '';

  sableMainCsp = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'none'; script-src 'self' 'wasm-unsafe-eval'; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self'";
  sableCallCsp = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'; script-src 'self' 'wasm-unsafe-eval'; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self'";
  cinnyCsp = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'; script-src 'self' 'wasm-unsafe-eval'; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self'";
  elementCsp = "default-src 'none'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'; script-src 'self' 'wasm-unsafe-eval'; script-src-attr 'none'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; worker-src 'self' blob:; manifest-src 'self'; img-src 'self' data: blob: https://${matrixHost}; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self' blob:";

  clientSecurityHeaders =
    {
      enforcedCsp,
      xFrameOptions,
    }:
    ''
      add_header Content-Security-Policy "${enforcedCsp}" always;
      add_header Permissions-Policy "camera=(self), microphone=(self), display-capture=(self), geolocation=(), payment=(), usb=()" always;
      add_header Referrer-Policy "no-referrer" always;
      add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-Frame-Options "${xFrameOptions}" always;
    '';
  sableSecurityHeaders = clientSecurityHeaders {
    enforcedCsp = sableMainCsp;
    xFrameOptions = "DENY";
  };
  sableCallSecurityHeaders = clientSecurityHeaders {
    enforcedCsp = sableCallCsp;
    xFrameOptions = "SAMEORIGIN";
  };
  cinnySecurityHeaders = clientSecurityHeaders {
    enforcedCsp = cinnyCsp;
    xFrameOptions = "SAMEORIGIN";
  };
  elementSecurityHeaders = clientSecurityHeaders {
    enforcedCsp = elementCsp;
    xFrameOptions = "SAMEORIGIN";
  };

  http3PrimaryConfig = ''
    listen 0.0.0.0:443 quic reuseport;
    http3 on;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
  '';
  http3Config = ''
    listen 0.0.0.0:443 quic;
    http3 on;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
  '';

  matrixProxyConfig = ''
    gzip off;
    brotli off;
    client_max_body_size 16M;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
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

  sable-unwrapped = pkgs.callPackage ../../packages/sable/package.nix { };
  sable =
    pkgs.runCommand "sable-${sable-unwrapped.version}-odarah" { nativeBuildInputs = [ pkgs.patch ]; }
      ''
        cp -R ${sable-unwrapped} "$out"
        chmod -R u+w "$out"
        printf '%s  %s\n' \
          b8444f59e9e451143a69b6aedd5b5d265629325975f298c1f56c40fa7d5159a1 "$out/index.html" \
          f2f8bfd1271beea279fed195e088fe86d7b26aaad51afc6237d5bf43e302feac "$out/public/element-call/index.html" \
          | ${pkgs.coreutils}/bin/sha256sum -c - || {
            echo "Sable ${sable-unwrapped.version} upstream HTML changed." >&2
            echo "Refresh guests/nginx/web-client-patches/sable-<version>.patch and these SHA-256 constants after reviewing the upstream HTML diff." >&2
            exit 1
          }
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        patch --batch --fuzz=0 --no-backup-if-mismatch -d "$out" -p1 < ${webClientPatches}/sable-1.21.0.patch
        mkdir -p "$out/csp-inline"
        install -m 0644 ${cspInline}/*.js "$out/csp-inline/"
        cat > "$out/config.json" <<'JSON'
        {
          "productName": "Sable",
          "defaultHomeserver": 0,
          "homeserverList": ["${matrixHost}"],
          "allowCustomHomeservers": false,
          "elementCallUrl": null,
          "disableAccountSwitcher": false,
          "hideUsernamePasswordFields": false,
          "featuredCommunities": { "openAsDefault": false, "spaces": [], "rooms": [], "servers": [] },
          "hashRouter": { "enabled": false, "basename": "/" }
        }
        JSON
        ${precompressStaticAssets} "$out"
      '';

  cinny =
    pkgs.runCommand "cinny-${pkgs.cinny-unwrapped.version}-odarah"
      { nativeBuildInputs = [ pkgs.patch ]; }
      ''
        cp -R ${pkgs.cinny-unwrapped} "$out"
        chmod -R u+w "$out"
        printf '%s  %s\n' \
          aecb677dd64bf6a88184537adbb133ccd872782b0c05b70743b307455c17ef8b "$out/index.html" \
          22e81071d91cce22ab9445a9145afb177fe5da118b7d90d445ef557b8b9d7434 "$out/public/element-call/index.html" \
          | ${pkgs.coreutils}/bin/sha256sum -c - || {
            echo "Cinny ${pkgs.cinny-unwrapped.version} upstream HTML changed." >&2
            echo "Refresh guests/nginx/web-client-patches/cinny-<version>.patch and these SHA-256 constants after reviewing the upstream HTML diff." >&2
            exit 1
          }
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        patch --batch --fuzz=0 --no-backup-if-mismatch -d "$out" -p1 < ${webClientPatches}/cinny-4.12.6.patch
        mkdir -p "$out/csp-inline"
        install -m 0644 ${cspInline}/*.js "$out/csp-inline/"
        cat > "$out/config.json" <<'JSON'
        {
          "defaultHomeserver": 0,
          "homeserverList": ["matrix.odarah.org"],
          "allowCustomHomeservers": false,
          "featuredCommunities": { "openAsDefault": false, "spaces": [], "rooms": [], "servers": [] },
          "hashRouter": { "enabled": false, "basename": "/" }
        }
        JSON
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
    };
  };
  elementConfigFile = pkgs.writeText "element-config.json" (builtins.toJSON elementConfig);
  element =
    pkgs.runCommand "element-web-${pkgs.element-web-unwrapped.version}-odarah"
      { nativeBuildInputs = [ pkgs.patch ]; }
      ''
        mkdir -p "$out"
        cp -R ${pkgs.element-web-unwrapped}/. "$out/"
        chmod -R u+w "$out"
        printf '%s  %s\n' \
          8861ff1b0cac31f4ba21fdf6c61745bfc3dcce52b7cb70fd7c328eea5b7d37e9 "$out/index.html" \
          e5a082d79cb2b2c4971776a1a9c8850976cebb8251f7b914053fcae25624528f "$out/widgets/element-call/index.html" \
          | ${pkgs.coreutils}/bin/sha256sum -c - || {
            echo "Element ${pkgs.element-web-unwrapped.version} upstream HTML changed." >&2
            echo "Refresh guests/nginx/web-client-patches/element-<version>.patch and these SHA-256 constants after reviewing the upstream HTML diff." >&2
            exit 1
          }
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        patch --batch --fuzz=0 --no-backup-if-mismatch -d "$out" -p1 < ${webClientPatches}/element-1.12.26.patch
        mkdir -p "$out/csp-inline"
        install -m 0644 ${cspInline}/*.js "$out/csp-inline/"
        cp ${elementConfigFile} "$out/config.json"
        ${precompressStaticAssets} "$out"
      '';
in
{
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs.${matrixHost} = {
      extraDomainNames = [
        odarahHost
        cinnyHost
        elementHost
        rtcHost
        sableHost
      ];
      profile = "shortlived";
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
    };
  };

  systemd.timers."acme-renew-${matrixHost}".timerConfig.AccuracySec = lib.mkForce "15min";
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
            --max-time 15 \
            --data-binary 'nginx のTLS証明書更新が失敗しました。' \
            "https://ntfy.sh/$topic" || true
        fi
      '';
    };

    unitConfig.StartLimitIntervalSec = 0;
  };

  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedBrotliSettings = true;

    # The public stream listener preserves Prosody's TLS termination while
    # forwarding Matrix TLS to the local HTTP virtual host. The intermediate
    # listeners remove PROXY protocol before Prosody and eturnal, but retain it
    # for Matrix so the HTTP proxy can pass the real client address to tuwunel.
    streamConfig = ''
      set_real_ip_from 127.0.0.1;

      map $ssl_preread_server_name $tls_dispatch {
        ${odarahHost} 127.0.0.1:9443;
        ${matrixHost} 127.0.0.1:9443;
        ${cinnyHost} 127.0.0.1:9443;
        ${elementHost} 127.0.0.1:9443;
        ${rtcHost} 127.0.0.1:9443;
        ${sableHost} 127.0.0.1:9443;
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
        listen 127.0.0.1:9443 proxy_protocol;
        proxy_protocol on;
        proxy_pass 127.0.0.1:8443;
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

    commonHttpConfig = ''
      set_real_ip_from 127.0.0.1;
      real_ip_header proxy_protocol;

      # Empty limit-zone keys are ignored, so only password-auth endpoints are
      # accounted while all Matrix traffic can share one simple proxy location.
      map $uri $matrix_password_auth {
        default 0;
        ~^/(?:_matrix/client/(?:r0|v[0-9]+|unstable)/login|_tuwunel/oidc/native)$ 1;
      }
      map $matrix_password_auth $matrix_login_ip_key {
        default "";
        1 $remote_addr;
      }
      map $matrix_password_auth $matrix_login_global_key {
        default "";
        1 $server_name;
      }

      # The per-IP bucket handles the common case. The deliberately looser
      # global bucket is a circuit breaker for distributed attacks.
      limit_req_zone $matrix_login_ip_key zone=matrix_login_ip:10m rate=1r/s;
      limit_req_zone $matrix_login_global_key zone=matrix_login_global:1m rate=10r/s;
      limit_conn_zone $matrix_login_global_key zone=matrix_login_conn:1m;
      limit_conn_zone $remote_addr zone=rtc_ws_conn:10m;

      map $request_uri $cinny_registration_loggable {
        default 1;
        ~^/register/ 0;
      }
      map $request_uri $cinny_cache_control {
        default "no-cache";
        ~^/csp-inline/ "no-cache";
        ~^/assets/ "public, max-age=31536000, immutable";
        ~^/register/ "no-store";
      }
      map $request_uri $element_cache_control {
        default "no-cache";
        ~^/csp-inline/ "no-cache";
        ~^/config(?:\.[^/]+)?\.json$ "no-store";
        ~^/bundles/[0-9a-f]+/ "public, max-age=31536000, immutable";
        ~^/widgets/element-call/assets/ "public, max-age=31536000, immutable";
        # element-web emits content-hashed filenames (7 hex chars as of 1.12.x)
        # outside /bundles/ too: fonts, i18n, img, icons, vector-icons, ...
        # Must stay below the config.json no-store entry; first regex match wins.
        # {7,} is spelled out because writeNginxConfig mangles brace quantifiers.
        ~\.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*\.[a-z0-9]+ "public, max-age=31536000, immutable";
      }
      map $uri $sable_cache_control {
        default "no-cache";
        ~^/csp-inline/ "no-cache";
        ~^/config\.json$ "no-store";
        ~^/assets/.*-[A-Za-z0-9_-]+\.(?:css|js|json|map|png|jpe?g|svg|webp|avif|wasm|woff2?|ttf|otf)$ "public, max-age=31536000, immutable";
      }
      map $http_upgrade $connection_upgrade {
        default upgrade;
        "" close;
      }
      access_log /var/log/nginx/access.log combined if=$cinny_registration_loggable;
    '';

    virtualHosts = {
      ${odarahHost} = {
        useACMEHost = matrixHost;
        forceSSL = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        extraConfig = http3Config;

        locations."= /" = {
          root = odarahLandingRoot;
          tryFiles = "/index.html =404";
          extraConfig = ''
            default_type text/html;
            charset utf-8;
            add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
            add_header Pragma "no-cache" always;
            ${landingSecurityHeaders}
          '';
        };
      };

      ${matrixHost} = {
        enableACME = true;
        forceSSL = true;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        extraConfig = http3Config;

        locations = {
          "= /" = {
            root = matrixLandingRoot;
            tryFiles = "/index.html =404";
            extraConfig = ''
              default_type text/html;
              charset utf-8;
              add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
              add_header Pragma "no-cache" always;
              ${landingSecurityHeaders}
            '';
          };

          "= /.well-known/matrix/client".extraConfig = ''
            default_type application/json;
            add_header Access-Control-Allow-Origin "*" always;
            return 200 '{"m.homeserver":{"base_url":"https://${matrixHost}"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://${rtcHost}"}]}';
          '';

          "= /.well-known/matrix/server".extraConfig = ''
            default_type application/json;
            return 200 '{"m.server":"${matrixHost}:443"}';
          '';

          "= /.well-known/matrix/support".extraConfig = ''
            default_type application/json;
            add_header Access-Control-Allow-Origin "*" always;
            return 200 '{"contacts":[{"role":"m.role.admin","matrix_id":"@odara:matrix.odarah.org","email_address":"hostmaster@s3-odara.net"}]}';
          '';

          "= /_tuwunel/oidc/account.css".extraConfig = ''
            alias ${oidcAccountCss};
            default_type text/css;
            add_header Cache-Control "no-cache" always;
            add_header X-Content-Type-Options "nosniff" always;
          '';

          "~ ^/(?:_matrix|_tuwunel)/" = {
            proxyPass = "http://${tuwunelAddress}:8008";
            extraConfig = ''
              limit_req zone=matrix_login_ip burst=5 nodelay;
              limit_req zone=matrix_login_global burst=20 nodelay;
              limit_conn matrix_login_conn 8;
              limit_req_status 429;
              limit_conn_status 429;
              ${matrixProxyConfig}
            '';
          };
        };
      };

      ${cinnyHost} = {
        useACMEHost = matrixHost;
        forceSSL = true;
        root = cinny;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        extraConfig = ''
          ${http3PrimaryConfig}
          ${cinnySecurityHeaders}
          add_header Cache-Control $cinny_cache_control always;
        '';

        locations = {
          "= /config.json".tryFiles = "$uri =404";
          "= /sw.js".tryFiles = "$uri =404";
          "= /index.html".tryFiles = "$uri =404";
          "^~ /csp-inline/".tryFiles = "$uri =404";
          "^~ /assets/".tryFiles = "$uri =404";
          "^~ /register/".extraConfig = ''
            access_log off;
            error_log /dev/null emerg;
            rewrite ^ /index.html break;
            try_files $uri =404;
          '';
          "^~ /public/element-call/".extraConfig = ''
            try_files $uri $uri/ =404;
          '';
          "^~ /public/".extraConfig = ''
            try_files $uri =404;
          '';
          "/".extraConfig = ''
            try_files $uri $uri/ /index.html;
          '';
        };
      };

      ${elementHost} = {
        useACMEHost = matrixHost;
        forceSSL = true;
        root = element;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        extraConfig = ''
          ${http3Config}
          ${elementSecurityHeaders}
          add_header Cache-Control $element_cache_control always;
        '';

        locations = {
          "= /decoder-ring/".return = "404";
          "^~ /decoder-ring/".return = "404";
          "~ ^/config(?:\\.[^/]+)?\\.json$".tryFiles = "$uri =404";
          "= /index.html".tryFiles = "$uri =404";
          "^~ /csp-inline/".tryFiles = "$uri =404";
          "^~ /bundles/".tryFiles = "$uri =404";
          "^~ /widgets/element-call/assets/".tryFiles = "$uri =404";
          "/".extraConfig = ''
            try_files $uri $uri/ /index.html;
          '';
        };
      };

      ${sableHost} = {
        useACMEHost = matrixHost;
        forceSSL = true;
        root = sable;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        extraConfig = ''
          ${http3Config}
          ${sableSecurityHeaders}
          add_header Cache-Control $sable_cache_control always;
        '';

        locations = {
          "= /config.json".tryFiles = "$uri =404";
          "= /index.html".tryFiles = "$uri =404";
          "= /manifest.json".tryFiles = "$uri =404";
          "= /sw.js".tryFiles = "$uri =404";
          "^~ /csp-inline/".tryFiles = "$uri =404";
          "^~ /assets/".tryFiles = "$uri =404";
          "^~ /public/element-call/".extraConfig = ''
            try_files $uri $uri/ =404;
            ${sableCallSecurityHeaders}
            add_header Cache-Control $sable_cache_control always;
            add_header Alt-Svc 'h3=":443"; ma=86400' always;
          '';
          "/".extraConfig = ''
            try_files $uri $uri/ /index.html;
          '';
        };
      };

      ${rtcHost} = {
        useACMEHost = matrixHost;
        forceSSL = true;
        extraConfig = http3Config;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
          {
            addr = "127.0.0.1";
            port = 8443;
            ssl = true;
            proxyProtocol = true;
          }
        ];
        locations = {
          "~ ^/(?:sfu/get|healthz|get_token)" = {
            proxyPass = "http://${rtcAddress}:8081";
            extraConfig = ''
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_set_header X-Forwarded-Proto https;
            '';
          };
          "/" = {
            proxyPass = "http://${rtcAddress}:7880";
            extraConfig = ''
              limit_conn rtc_ws_conn 20;
              limit_conn_status 429;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_set_header X-Forwarded-Proto https;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection $connection_upgrade;
              proxy_read_timeout 3600s;
              proxy_send_timeout 3600s;
            '';
          };
        };
      };

      "xmpp-http" = {
        serverName = "xmpp.odarah.org";
        serverAliases = [
          "conference.xmpp.odarah.org"
          "share.xmpp.odarah.org"
        ];
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];

        locations = {
          "^~ /.well-known/acme-challenge/" = {
            proxyPass = "http://${prosodyAddress}:80";
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
            '';
          };
          "/".return = "301 https://$host$request_uri";
        };
      };

      "turn-http" = {
        serverName = "turn.odarah.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations = {
          "^~ /.well-known/acme-challenge/" = {
            proxyPass = "http://${rtcAddress}:80";
            extraConfig = ''
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
            '';
          };
          "/".return = "301 https://$host$request_uri";
        };
      };

      "reject-http" = {
        default = true;
        serverName = "_";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/".return = "444";
      };
    };
  };

  sops.secrets.ntfy_topic = { };

  services.logrotate.settings.nginx = {
    frequency = "daily";
    rotate = 14;
    maxage = 14;
    maxsize = "200M";
  };

  system.stateVersion = "26.05";
}
