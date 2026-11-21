{
  config,
  configurationName,
  lib,
  pkgs,
  sable-unwrapped,
  ...
}:

let
  oneshotHardening = import ../../modules/guest/oneshot-hardening.nix;
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
  oidcRoot = pkgs.linkFarm "oidc-root" [
    {
      name = "tuwunel-oidc.css";
      path = ./tuwunel-oidc.css;
    }
  ];
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

  webClients = import ./web-clients.nix {
    inherit
      pkgs
      sable-unwrapped
      matrixHost
      guestMatrixHost
      rtcHost
      sableHost
      pushHost
      ;
  };

  caddyPackage = pkgs.caddy.withPlugins {
    plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.0" ];
    hash = "sha256-d4VdlHHF0cqzknO7eS+l9uI2fpCfTQWEirx/5PMHzLk=";
  };

  caddyConfig = pkgs.runCommand "nginx-Caddyfile" { } ''
    substitute ${./Caddyfile} "$out" \
      --subst-var-by ODARAH_LANDING_ROOT ${lib.escapeShellArg (toString odarahLandingRoot)} \
      --subst-var-by MATRIX_LANDING_ROOT ${lib.escapeShellArg (toString matrixLandingRoot)} \
      --subst-var-by ELEMENT_CALL_ROOT ${lib.escapeShellArg (toString webClients.elementCall)} \
      --subst-var-by CINNY_ROOT ${lib.escapeShellArg (toString webClients.cinny)} \
      --subst-var-by ELEMENT_ROOT ${lib.escapeShellArg (toString webClients.element)} \
      --subst-var-by SABLE_ROOT ${lib.escapeShellArg (toString webClients.sable)} \
      --subst-var-by OIDC_ROOT ${lib.escapeShellArg (toString oidcRoot)} \
      --subst-var-by LANDING_CSP "$(<${webClients.cspPolicies}/landing.csp)" \
      --subst-var-by SABLE_CSP "$(<${webClients.cspPolicies}/sable.csp)" \
      --subst-var-by CINNY_CSP "$(<${webClients.cspPolicies}/cinny.csp)" \
      --subst-var-by CINNY_CALL_CSP "$(<${webClients.cspPolicies}/cinny-call.csp)" \
      --subst-var-by ELEMENT_CSP "$(<${webClients.cspPolicies}/element.csp)" \
      --subst-var-by ELEMENT_EMBEDDED_CALL_CSP "$(<${webClients.cspPolicies}/element-embedded-call.csp)" \
      --subst-var-by ELEMENT_CALL_CSP "$(<${webClients.cspPolicies}/element-call.csp)"
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
  # Keep these build targets available for the update script and CI.
  system.build = {
    inherit (webClients) sable webClientDiffs;
    inherit caddyConfig caddyRuntimeConfig;
  };

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
      extraLegoRenewFlags = [ "--reuse-key" ];
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

  systemd.services.guest-registration-blocklist = {
    description = "Refresh the guest registration IP blocklist";
    after = [ "caddy.service" ];
    serviceConfig = oneshotHardening.base // {
      Type = "oneshot";
      User = config.services.caddy.user;
      Group = config.services.caddy.group;
      StateDirectory = "guest-registration-blocklist";
      StateDirectoryMode = "0700";
      ExecStart = "${pkgs.python3Minimal}/bin/python3 ${./update-guest-registration-blocklist.py} /var/log/caddy/guest-registration.log /var/lib/guest-registration-blocklist";
      InaccessiblePaths = [
        "-/run/caddy"
        "-/run/secrets"
        "-/var/lib/acme"
        "-/var/lib/caddy"
      ];
      PrivateNetwork = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      Nice = 10;
      MemoryMax = "128M";
      TasksMax = 16;
    };
  };

  systemd.timers.guest-registration-blocklist = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
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
