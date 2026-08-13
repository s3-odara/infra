{ ... }:

{
  security = {
    apparmor.enable = true;
    protectKernelImage = true;
  };

  boot = {
    kernelParams = [
      "init_on_alloc=1"
      "page_alloc.shuffle=1"
      "slab_nomerge"
      "mitigations=auto"
      "vsyscall=none"
      "vdso32=0"
      "hash_pointers=always"
      "randomize_kstack_offset=on"
      "hardened_usercopy=1"
      "proc_mem.force_override=ptrace"
      "oops=panic"
      "lockdown=integrity"
      "panic=10"
    ];

    kernel.sysctl = {
      "kernel.kptr_restrict" = 2;
      "kernel.yama.ptrace_scope" = 1;
      "kernel.dmesg_restrict" = 1;
      "kernel.randomize_va_space" = 2;
      "dev.tty.ldisc_autoload" = 0;
      "dev.tty.legacy_tiocsti" = 0;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      "fs.protected_symlinks" = 1;
      "fs.protected_hardlinks" = 1;
      "fs.suid_dumpable" = 0;
      "kernel.io_uring_disabled" = 1;
      "kernel.io_uring_group" = -1;
      "kernel.warn_limit" = 0;
      "kernel.oops_limit" = 1;

      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
    };
  };
}
