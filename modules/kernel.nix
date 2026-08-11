{ pkgs, ... }:

let
  kernelBase = pkgs.linuxPackages_latest.kernel;

  vpsKernel = pkgs.linuxManualConfig {
    inherit (kernelBase)
      version
      src
      modDirVersion
      kernelPatches
      ;

    configfile = ../kernel/vps.config;
    features = kernelBase.features;
    stdenv = pkgs.llvmPackages.stdenv;
    extraMakeFlags = [ "LLVM=1" ];
  };
in
{
  boot = {
    kernelPackages = pkgs.linuxPackagesFor vpsKernel;
  };
}
