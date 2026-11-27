{
  pkgs,
  sable-unwrapped,
  matrixHost,
  guestMatrixHost,
  rtcHost,
  sableHost,
  pushHost,
}:

let
  pushClientConfig = builtins.fromJSON (builtins.readFile ../../packages/sygnal/client-config.json);
  webClientHtml = pkgs.callPackage ../../packages/web-client-html/package.nix { };

  # Fixed styles injected by react-colorful and the patched drag-and-drop fix.
  # PDF.js only injects a font stylesheet when document.fonts is unavailable;
  # browsers supporting the CSP Level 3 directives below use its FontFace path.
  cinnyStyleHashes = "'sha256-I2px+fnpbN4E5+Djrj7aoTIyq9yyREkuVl19f4Sye9A=' 'sha256-gE6f9B7Di/6xvPsuFkoYXxNapPKVLAmRBvP73rpQ9+Y='";
  clientCsp =
    {
      homeserver ? matrixHost,
      frameAncestors ? "'none'",
      styleDirectives ? [ "style-src 'self' 'unsafe-inline'" ],
      frameSrc ? "'self'",
    }:
    hashes:
    let
      homeserverSrc = if homeserver == null then "" else " https://${homeserver}";
    in
    builtins.concatStringsSep "; " (
      [
        "default-src 'none'"
        "base-uri 'none'"
        "object-src 'none'"
        "form-action 'self'"
        "frame-ancestors ${frameAncestors}"
        "script-src 'self' 'wasm-unsafe-eval' ${hashes}"
        "script-src-attr 'none'"
      ]
      ++ styleDirectives
      ++ [
        "font-src 'self' data:"
        "worker-src 'self' blob:"
        "manifest-src 'self'"
        "img-src 'self' data: blob:${homeserverSrc}"
        "media-src 'self' blob:${homeserverSrc}"
        "connect-src 'self'${homeserverSrc} https://${rtcHost} wss://${rtcHost}"
      ]
      ++ (if frameSrc == null then [ ] else [ "frame-src ${frameSrc}" ])
    );

  sableCsp = clientCsp {
    frameSrc = null; # Fall back to default-src 'none'.
  };
  cinnyCsp = clientCsp {
    frameAncestors = "'self'";
    styleDirectives = [
      "style-src 'self' ${cinnyStyleHashes}"
      "style-src-elem 'self' ${cinnyStyleHashes}"
      "style-src-attr 'none'"
    ];
  };
  cinnyCallCsp = clientCsp { frameAncestors = "'self'"; };
  elementCsp = clientCsp {
    frameAncestors = "'self'";
    frameSrc = "'self' blob:";
  };
  elementCallCsp = clientCsp {
    homeserver = null; # Served on guestMatrixHost ('self').
    frameSrc = null; # Fall back to default-src 'none'.
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
      printf '%s\n' "${policy "$hashes"}" > ${output}
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

  sable = pkgs.runCommand "sable-${sableWithLocalDictionary.version}-odarah" { } ''
    cp -R ${sableWithLocalDictionary} "$out"
    chmod -R u+w "$out"
    # Add after the web build so the service worker does not precache it.
    install -Dm644 ${sableDictionary} "$out/${sableDictionaryPath}"
    install -m644 ${sableDictionaryLicense} "$out/assets/jieba-LICENSE.txt"
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
    # Deployment headers are owned by this IaC, not the upstream files.
    rm "$out/csp.caddy" "$out/_headers"
    ${precompressStaticAssets} "$out"
  '';

  cinny = pkgs.runCommand "cinny-${pkgs.cinny-unwrapped.version}-odarah" { } ''
    cp -R ${pkgs.cinny-unwrapped} "$out"
    chmod -R u+w "$out"
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
      "homeserverList": ["${matrixHost}"],
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
      guest_spa_url = "https://${guestMatrixHost}";
    };
  };
  elementConfigFile = pkgs.writeText "element-config.json" (builtins.toJSON elementConfig);
  elementCallConfig = {
    default_server_config."m.homeserver" = {
      base_url = "https://${guestMatrixHost}";
      server_name = guestMatrixHost;
    };
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
      { nativeBuildInputs = [ webClientHtml ]; }
      ''
        mkdir -p "$out"
        cp -R ${pkgs.element-web-unwrapped}/. "$out/"
        chmod -R u+w "$out"
        web-client-html remove-meta-csp "$out/index.html"
        ${pkgs.findutils}/bin/find "$out" -type f \( -name '*.gz' -o -name '*.br' \) -delete
        cp ${elementConfigFile} "$out/config.json"
        ${precompressStaticAssets} "$out"
      '';

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
in
{
  inherit
    sable
    cinny
    element
    elementCall
    cspPolicies
    ;
}
