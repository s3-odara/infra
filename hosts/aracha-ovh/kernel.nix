{ pkgs, ... }:

let
  kernelBase = pkgs.linuxPackages_latest.kernel;

  hostKernel =
    (pkgs.linuxManualConfig {
      inherit (kernelBase)
        version
        src
        modDirVersion
        kernelPatches
        ;

      configfile = ./kernel.config;
      features = kernelBase.features;
      stdenv = pkgs.llvmPackages.stdenv;
      extraMakeFlags = [
        "LLVM=1"
        "LD=${pkgs.llvmPackages.lld}/bin/ld.lld"
      ];
    }).overrideAttrs
      (oldAttrs: {
        # NixOS uses the built-in module metadata when constructing the initrd,
        # even when loadable module support is disabled.
        postInstall = (oldAttrs.postInstall or "") + ''
          moduleMetadata="$out/lib/modules/${kernelBase.modDirVersion}"
          mkdir -p "$moduleMetadata"
          install -m 0644 modules.builtin modules.builtin.modinfo "$moduleMetadata/"
          install -m 0644 /dev/null "$moduleMetadata/modules.order"
          depmod -b "$out" ${kernelBase.modDirVersion}
        '';
      });

  # Host hardware and the root filesystem boot path.
  requiredPlatformBuiltins = [
    "ACPI"
    "BLK_DEV_INITRD"
    "BLK_DEV_SD"
    "BTRFS_FS"
    "BTRFS_FS_POSIX_ACL"
    "DEVTMPFS"
    "EFI_PARTITION"
    "PCI"
    "SCSI"
    "SCSI_VIRTIO"
    "SERIAL_8250"
    "SERIAL_8250_CONSOLE"
    "TMPFS"
    "TTY"
    "UNIX98_PTYS"
    "VIRTIO"
    "VIRTIO_BALLOON"
    "VIRTIO_CONSOLE"
    "VIRTIO_NET"
    "VIRTIO_PCI"
  ];

  # Kernel interfaces required by the NixOS/systemd userspace baseline.
  requiredSystemBuiltins = [
    "AUTOFS_FS"
    "CGROUPS"
    "CRYPTO_HMAC"
    "CRYPTO_SHA256"
    "DMIID"
    "EPOLL"
    "FHANDLE"
    "INOTIFY_USER"
    "NET"
    "PROC_FS"
    "SECCOMP"
    "SECCOMP_FILTER"
    "SIGNALFD"
    "SYSFS"
    "TIMERFD"
    "TMPFS_POSIX_ACL"
    "TMPFS_XATTR"
    "UNIX"
  ];

  # Incus containers, nftables networking, and WireGuard.
  requiredWorkloadBuiltins = [
    "BRIDGE"
    "BRIDGE_NETFILTER"
    "CGROUP_DEVICE"
    "CGROUP_FREEZER"
    "CGROUP_PIDS"
    "CPUSETS"
    "FUSE_FS"
    "INET"
    "IPC_NS"
    "IP6_NF_IPTABLES"
    "IP6_NF_MATCH_RPFILTER"
    "IP_NF_IPTABLES"
    "IP_NF_MATCH_RPFILTER"
    "KEYS"
    "MEMCG"
    "NAMESPACES"
    "NETFILTER"
    "NETFILTER_FAMILY_BRIDGE"
    "NETFILTER_NETLINK"
    "NETFILTER_XTABLES"
    "NETFILTER_XT_MATCH_COMMENT"
    "NETFILTER_XT_MATCH_CONNTRACK"
    "NETFILTER_XT_MATCH_PKTTYPE"
    "NETFILTER_XT_TARGET_CHECKSUM"
    "NETFILTER_XT_TARGET_MASQUERADE"
    "NET_NS"
    "NF_CONNTRACK"
    "NF_CONNTRACK_BRIDGE"
    "NF_CT_NETLINK"
    "NF_NAT"
    "NF_NAT_MASQUERADE"
    "NF_TABLES"
    "NF_TABLES_BRIDGE"
    "NF_TABLES_INET"
    "NFT_BRIDGE_META"
    "NFT_COMPAT"
    "NFT_CT"
    "NFT_FIB"
    "NFT_FIB_INET"
    "NFT_MASQ"
    "NFT_NAT"
    "PACKET"
    "PID_NS"
    "POSIX_MQUEUE"
    "SYN_COOKIES"
    "TIME_NS"
    "USER_NS"
    "UTS_NS"
    "VETH"
    "WIREGUARD"
  ];

  # Intentional compile-time hardening policy.
  requiredSecurityBuiltins = [
    "BUG_ON_DATA_CORRUPTION"
    "CFI"
    "DEBUG_WX"
    "FORTIFY_SOURCE"
    "HARDENED_USERCOPY"
    "HARDENED_USERCOPY_DEFAULT_ON"
    "INIT_ON_ALLOC_DEFAULT_ON"
    "INIT_STACK_ALL_ZERO"
    "KFENCE"
    "LEGACY_VSYSCALL_NONE"
    "LIST_HARDENED"
    "LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY"
    "PAGE_TABLE_CHECK"
    "PAGE_TABLE_CHECK_ENFORCED"
    "PANIC_ON_OOPS"
    "RANDOMIZE_BASE"
    "RANDOMIZE_KSTACK_OFFSET_DEFAULT"
    "RANDOMIZE_MEMORY"
    "RANDOM_KMALLOC_CACHES"
    "RANDSTRUCT_FULL"
    "SECURITY_APPARMOR"
    "SECURITY_DMESG_RESTRICT"
    "SECURITY_LANDLOCK"
    "SECURITY_LOCKDOWN_LSM"
    "SECURITY_LOCKDOWN_LSM_EARLY"
    "SECURITY_YAMA"
    "SHUFFLE_PAGE_ALLOCATOR"
    "SLAB_FREELIST_HARDENED"
    "SLAB_FREELIST_RANDOM"
    "STACKPROTECTOR_STRONG"
    "STRICT_KERNEL_RWX"
    "UBSAN"
    "UBSAN_TRAP"
    "VMAP_STACK"
    "X86_KERNEL_IBT"
    "X86_UMIP"
    "X86_USER_SHADOW_STACK"
    "ZERO_CALL_USED_REGS"
  ];

  requiredBuiltins =
    requiredPlatformBuiltins
    ++ requiredSystemBuiltins
    ++ requiredWorkloadBuiltins
    ++ requiredSecurityBuiltins;

  # Intentionally removed kernel interfaces and dynamic extension mechanisms.
  requiredDisabled = [
    "BINFMT_MISC"
    "BPF_SYSCALL"
    "CHECKPOINT_RESTORE"
    "DEVMEM"
    "DEVKMEM"
    "FTRACE"
    "HIBERNATION"
    "IA32_EMULATION"
    "IO_URING"
    "KEXEC"
    "KEXEC_FILE"
    "KPROBES"
    "MODIFY_LDT_SYSCALL"
    "MODULES"
    "MODULE_SIG"
    "PROC_KCORE"
    "USERFAULTFD"
    "X86_X32_ABI"
  ];

  # Normalize the checked-in config against the same source, patches, compiler,
  # and make flags as the real kernel without compiling the kernel itself.
  generatedKernelConfig = hostKernel.overrideAttrs (_: {
    pname = "aracha-ovh-kernel-config";
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

  assertions =
    map (option: {
      assertion = hostKernel.config.isYes option;
      message = "aracha-ovh requires CONFIG_${option}=y";
    }) requiredBuiltins
    ++ map (option: {
      assertion = hostKernel.config.isDisabled option;
      message = "aracha-ovh requires CONFIG_${option}=n";
    }) requiredDisabled;
}
