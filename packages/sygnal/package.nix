{
  fetchFromGitHub,
  lib,
  python312Packages,
}:

let
  # Follow upstream's Python runtime; pin only incompatible locked dependencies locally.
  python3Packages = python312Packages;
  pins = builtins.fromJSON (builtins.readFile ./pins.json);

  opentracing = python3Packages.buildPythonPackage rec {
    pname = "opentracing";
    version = "2.4.0";
    format = "setuptools";

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = "sha256-oXMRfm71gNVYdHNNH6fstvNlUWC4uJdKKh6Y5eychA0=";
    };

    dependencies = [ python3Packages.six ];
    doCheck = false;
  };

  jaeger-client = python3Packages.buildPythonPackage rec {
    pname = "jaeger-client";
    version = "4.8.0";
    format = "setuptools";

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = "sha256-MVeDbtq44sIJvS1q5hET2zb37jmeZrHcu3Fdh6tJv+A=";
    };

    dependencies = [
      opentracing
      python3Packages.prometheus-client
      python3Packages.six
      python3Packages.threadloop
      python3Packages.tornado
    ];
    doCheck = false;
  };

  # Sygnal's custom Twisted request adapter implements the response interface
  # expected by the version locked upstream, but not pywebpush 2.3 or newer.
  pywebpush = python3Packages.buildPythonPackage rec {
    pname = "pywebpush";
    version = "2.0.0";
    pyproject = true;

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = "sha256-A8zD6XW2A3S3Y0xJVZVha+Ujvyx9oNl26E/amsjGMwE=";
    };

    build-system = [ python3Packages.setuptools ];
    dependencies = with python3Packages; [
      aiohttp
      cryptography
      http-ece
      py-vapid
      requests
      six
    ];
    pythonImportsCheck = [ "pywebpush" ];
  };
in
python3Packages.buildPythonApplication rec {
  pname = "matrix-sygnal";
  version = pins.version;
  pyproject = true;

  src = fetchFromGitHub {
    owner = "element-hq";
    repo = "sygnal";
    rev = "v${version}";
    hash = pins.srcHash;
  };

  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail 'aioapns = ">=3.0,<4.0"' 'aioapns = ">=3.0,<5.0"' \
      --replace-fail 'prometheus_client = ">=0.7.0,<0.8"' 'prometheus_client = ">=0.7.0,<1.0"'
  '';

  build-system = [ python3Packages.poetry-core ];

  dependencies = with python3Packages; [
    aioapns
    aiohttp
    attrs
    cryptography
    google-auth
    idna
    jaeger-client
    matrix-common
    opentracing
    prometheus-client
    py-vapid
    pyopenssl
    pywebpush
    pyyaml
    sentry-sdk
    service-identity
    twisted
    zope-interface
  ];

  pythonImportsCheck = [
    "sygnal.sygnal"
    "sygnal.webpushpushkin"
  ];

  meta = {
    description = "Reference Push Gateway for Matrix notifications";
    homepage = "https://github.com/element-hq/sygnal";
    changelog = "https://github.com/element-hq/sygnal/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.agpl3Only;
    mainProgram = "sygnal";
    platforms = lib.platforms.linux;
  };
}
