{ pkgs, ... }:

let
  kernelBase = pkgs.linuxPackages_latest.kernel;

  hostKernel = pkgs.linuxManualConfig {
    inherit (kernelBase)
      version
      src
      modDirVersion
      kernelPatches
      ;

    configfile = ./kernel.config;
    features = kernelBase.features;
    stdenv = pkgs.llvmPackages.stdenv;
    extraMakeFlags = [ "LLVM=1" ];
  };

  # Normalize the checked-in config against the same source, patches, compiler,
  # and make flags as the real kernel without compiling the kernel itself.
  generatedKernelConfig = hostKernel.overrideAttrs (_: {
    pname = "incus-01-kernel-config";
    outputs = [ "out" ];
    installFlags = [ ];

    configurePhase = ''
      runHook preConfigure

      mkdir build
      export buildRoot="$PWD/build"
      cp ${./kernel.config} "$buildRoot/.config"
      chmod u+w "$buildRoot/.config"
      make "''${makeFlags[@]}" olddefconfig

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp "$buildRoot/.config" "$out"
      runHook postInstall
    '';

    postInstall = "";
    preFixup = "";
  });
in
{
  boot.kernelPackages = pkgs.linuxPackagesFor hostKernel;
  system.build.kernelConfig = generatedKernelConfig;
}
