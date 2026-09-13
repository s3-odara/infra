{ lib, ... }:

let
  blockedAddressRanges = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
    "::/128"
    "::1/128"
    "::ffff:0:0/96"
    "64:ff9b::/96"
    "64:ff9b:1::/48"
    "100::/64"
    "2001::/32"
    "2001:2::/48"
    "2001:db8::/32"
    "2002::/16"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
  ];
in
{
  # Provide the host and every Incus guest with a shared recursive cache.
  # Unbound listens on loopback; Incus dnsmasq follows the host's resolv.conf
  # and provides the resolver to guests over the managed bridge.
  services.unbound = {
    enable = true;
    resolveLocalQueries = true;
    enableRootTrustAnchor = false;

    settings.server = {

      # Iterate from the DNS root without a forwarding resolver. Omit the
      # validator and explicitly suppress DO on upstream requests so DNSSEC
      # records cannot enlarge responses even if a future client requests them.
      module-config = "iterator";
      disable-edns-do = true;

      # Reduce query disclosure and reject malformed or out-of-bailiwick data.
      qname-minimisation = true;
      minimal-responses = true;
      harden-glue = true;
      harden-unverified-glue = true;
      harden-referral-path = true;
      harden-unknown-additional = true;
      iter-scrub-promiscuous = true;
      use-caps-for-id = true;
      harden-large-queries = true;
      harden-short-bufsize = true;
      hide-identity = true;
      hide-version = true;

      # Keep UDP DNS within the classic 512-byte limit to avoid fragmentation;
      # larger answers fall back to TCP.
      edns-buffer-size = 512;
      max-udp-size = 4096;

      # Do not return special-use addresses learned from public DNS, or send
      # recursive queries to malicious delegations within those ranges.
      private-address = blockedAddressRanges;
      do-not-query-address = blockedAddressRanges;
      do-not-query-localhost = true;
      ip-freebind = false;

      # Bound abusive or pathological recursion while preserving cached replies.
      deny-any = true;
      ratelimit = 1000;
      ratelimit-backoff = true;
      wait-limit = 1000;
      wait-limit-cookie = 1000;
      max-sent-count = 32;
      max-query-restarts = 11;
      unwanted-reply-threshold = 10000000;

      # Connect UDP sockets to their peers to mitigate ICMP side-channel leaks,
      # and retain timed-out ports briefly so late replies cannot hit reused ones.
      udp-connect = true;
      delay-close = 1500;

      # Prefer a stale cached answer over a federation outage while an
      # authoritative server is temporarily unavailable. Wait up to three
      # seconds for a fresh answer before serving stale data.
      prefetch = true;
      serve-expired = true;
      serve-expired-ttl = 3600;
      serve-expired-reply-ttl = 30;
      serve-expired-client-timeout = 3000;
      discard-timeout = 4000;
    };
  };

  # Binding the DNS service port requires CAP_NET_BIND_SERVICE. The NixOS
  # module also grants CAP_NET_RAW for transparent DNS, which is not used here.
  systemd.services.unbound.serviceConfig = {
    AmbientCapabilities = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
    PrivateIPC = true;
    UMask = "0077";
  };
}
