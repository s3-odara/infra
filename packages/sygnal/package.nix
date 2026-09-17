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
    version = pins.python.opentracing.version;
    format = "setuptools";

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = pins.python.opentracing.hash;
    };

    dependencies = [ python3Packages.six ];
    doCheck = false;
  };

  jaeger-client = python3Packages.buildPythonPackage rec {
    pname = "jaeger-client";
    version = pins.python."jaeger-client".version;
    format = "setuptools";

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = pins.python."jaeger-client".hash;
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

  # pywebpush 2.3 accesses response.headers, which Sygnal's
  # HttpDelayedRequest does not provide.
  pywebpush = python3Packages.buildPythonPackage rec {
    pname = "pywebpush";
    version = pins.python.pywebpush.version;
    pyproject = true;

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = pins.python.pywebpush.hash;
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

  # This profiler timing test is flaky under the parallel test runner: the
  # profile chunk can be empty even though the span has its profiler ID.
  sentry-sdk = python3Packages.sentry-sdk.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or [ ]) ++ [ "test_segment_span_has_profiler_id" ];
  });

  # Twisted 26 stalls Sygnal's _AgentBase-based Apple Web Push requests,
  # causing the Push Gateway to return 504.
  twisted = python3Packages.buildPythonPackage rec {
    pname = "twisted";
    version = pins.python.twisted.version;
    pyproject = true;

    src = python3Packages.fetchPypi {
      inherit pname version;
      hash = pins.python.twisted.hash;
    };

    build-system = with python3Packages; [
      hatch-fancy-pypi-readme
      hatchling
      incremental
      setuptools
    ];
    dependencies = with python3Packages; [
      attrs
      automat
      constantly
      hyperlink
      incremental
      typing-extensions
      zope-interface
      # TLS support used for web push delivery over HTTPS
      idna
      pyopenssl
      service-identity
    ];
    doCheck = false;
  };
in
python3Packages.buildPythonApplication rec {
  pname = "matrix-sygnal";
  version = pins.version;
  pyproject = true;

  src = fetchFromGitHub {
    owner = "element-hq";
    repo = "sygnal";
    # The updater resolves and verifies the signed tag once, then pins its commit.
    rev = pins.commit;
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
