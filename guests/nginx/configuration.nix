{
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  matrixHost = "matrix.odarah.org";
  cinnyHost = "cinny.matrix.odarah.org";
  elementHost = "element.matrix.odarah.org";
  rtcHost = "rtc.matrix.odarah.org";
  prosodyAddress = "10.77.3.10";
  tuwunelAddress = "10.77.3.14";
  rtcAddress = "10.77.3.15";
  oidcAccountCss = ./tuwunel-oidc.css;

  cinnySecurityHeaders = ''
    add_header Content-Security-Policy "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; form-action 'self'; script-src 'self' 'wasm-unsafe-eval' 'sha256-dT6noyex1I8o5CS9Sx/y8UOqwpZYIridpGz92gcObIM=' 'sha256-pQY0fuQAnnVQH5nQfjo80rzGkQzeN3JeAtAJ+1KcD4k=' 'sha256-3042zLa3JXvrJe/2n8P/XpIKwqBdNTu7fwbLZUNrzZQ='; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://matrix.odarah.org; font-src 'self' data:; media-src 'self' blob: https://matrix.odarah.org; connect-src 'self' https://matrix.odarah.org wss://matrix.odarah.org https://${rtcHost} wss://${rtcHost}; worker-src 'self' blob:" always;
    add_header Permissions-Policy "camera=(self), microphone=(self), display-capture=(self), geolocation=(), payment=(), usb=()" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
  '';

  elementSecurityHeaders = ''
    add_header Content-Security-Policy "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; form-action 'self'; script-src 'self' 'wasm-unsafe-eval' 'sha256-pQY0fuQAnnVQH5nQfjo80rzGkQzeN3JeAtAJ+1KcD4k=' 'sha256-3042zLa3JXvrJe/2n8P/XpIKwqBdNTu7fwbLZUNrzZQ='; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://${matrixHost}; font-src 'self' data:; media-src 'self' blob: https://${matrixHost}; connect-src 'self' https://${matrixHost} wss://${matrixHost} https://${rtcHost} wss://${rtcHost}; frame-src 'self' blob:; worker-src 'self' blob:; manifest-src 'self'" always;
    add_header Permissions-Policy "camera=(self), microphone=(self), display-capture=(self), geolocation=(), payment=(), usb=()" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
  '';

  cinny = pkgs.runCommand "cinny-${pkgs.cinny-unwrapped.version}-odarah" { } ''
    cp -R ${pkgs.cinny-unwrapped} "$out"
    chmod u+w "$out/config.json"
    cat > "$out/config.json" <<'JSON'
    {
      "defaultHomeserver": 0,
      "homeserverList": ["matrix.odarah.org"],
      "allowCustomHomeservers": false,
      "featuredCommunities": { "openAsDefault": false, "spaces": [], "rooms": [], "servers": [] },
      "hashRouter": { "enabled": false, "basename": "/" }
    }
    JSON
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
  element = pkgs.runCommand "element-web-${pkgs.element-web-unwrapped.version}-odarah" { } ''
    mkdir -p "$out"
    ln -s ${pkgs.element-web-unwrapped}/* "$out"
    rm "$out/config.json"
    ln -s ${elementConfigFile} "$out/config.json"
  '';
in
{
  boot.isContainer = true;
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs.${matrixHost} = {
      extraDomainNames = [
        cinnyHost
        elementHost
        rtcHost
      ];
      profile = "shortlived";
      validMinDays = 4;
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
    };
  };

  systemd.timers."acme-renew-${matrixHost}".timerConfig.AccuracySec = lib.mkForce "15min";
  systemd.services."acme-order-renew-${matrixHost}".serviceConfig = {
    Restart = "on-failure";
    RestartSteps = 4;
    RestartMaxDelaySec = "6h";
  };

  services.nginx = {
    enable = true;

    # The public stream listener preserves Prosody's TLS termination while
    # forwarding Matrix TLS to the local HTTP virtual host. The intermediate
    # listeners remove PROXY protocol before Prosody and coturn, but retain it
    # for Matrix so the HTTP proxy can pass the real client address to tuwunel.
    streamConfig = ''
      set_real_ip_from 127.0.0.1;

      map $ssl_preread_server_name $tls_dispatch {
        ${matrixHost} 127.0.0.1:9443;
        ${cinnyHost} 127.0.0.1:9443;
        ${elementHost} 127.0.0.1:9443;
        ${rtcHost} 127.0.0.1:9443;
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

      map $request_uri $cinny_registration_loggable {
        default 1;
        ~^/register/ 0;
      }
      map $request_uri $cinny_cache_control {
        default "no-cache";
        ~^/assets/ "public, max-age=31536000, immutable";
        ~^/register/ "no-store";
      }
      map $request_uri $element_cache_control {
        default "no-cache";
        ~^/config(?:\.[^/]+)?\.json$ "no-store";
        ~^/bundles/[0-9a-f]+/ "public, max-age=31536000, immutable";
        ~^/widgets/element-call/assets/ "public, max-age=31536000, immutable";
      }
      map $http_upgrade $connection_upgrade {
        default upgrade;
        "" close;
      }
      access_log /var/log/nginx/access.log combined if=$cinny_registration_loggable;
    '';

    virtualHosts = {
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

        locations = {
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
              client_max_body_size 24M;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_set_header X-Forwarded-Proto https;
              proxy_read_timeout 300s;
              proxy_send_timeout 300s;
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
          ${cinnySecurityHeaders}
          add_header Cache-Control $cinny_cache_control always;
        '';

        locations = {
          "= /config.json".tryFiles = "$uri =404";
          "= /sw.js".tryFiles = "$uri =404";
          "= /index.html".tryFiles = "$uri =404";
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
          ${elementSecurityHeaders}
          add_header Cache-Control $element_cache_control always;
        '';

        locations = {
          "~ ^/config(?:\\.[^/]+)?\\.json$".tryFiles = "$uri =404";
          "= /index.html".tryFiles = "$uri =404";
          "^~ /bundles/".tryFiles = "$uri =404";
          "^~ /widgets/element-call/assets/".tryFiles = "$uri =404";
          "/".extraConfig = ''
            try_files $uri $uri/ /index.html;
          '';
        };
      };

      ${rtcHost} = {
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

  services.logrotate.settings.nginx = {
    frequency = "daily";
    rotate = 14;
    maxage = 14;
    maxsize = "200M";
  };

  system.stateVersion = "26.05";
}
