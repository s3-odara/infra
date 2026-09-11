{ configurationName, pkgs, ... }:

{
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.matrix-tuwunel = {
    enable = true;
    settings.global = {
      server_name = "guest.matrix.odarah.org";
      address = [ "10.77.3.17" ];
      port = [ 8008 ];
      ip_source = "rightmost_x_forwarded_for";
      ip_lookup_strategy = 1;

      max_request_size = 16 * 1024 * 1024;
      max_response_size = 64 * 1024 * 1024;
      cache_capacity_modifier = 0.25;
      db_cache_capacity_mb = 64;
      db_write_buffer_capacity_mb = 32;
      rocksdb_allow_fallocate = false;

      allow_registration = true;
      allow_guest_registration = false;
      yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse = true;
      new_user_displayname_suffix = "";
      grant_admin_to_first_user = false;
      create_admin_room = false;
      admin_escape_commands = false;
      admin_signal_execute = [ "media delete-range 2d --older-than" ];
      federate_admin_room = false;

      allow_federation = true;
      allowed_remote_server_names_experimental = [ "^matrix\\.odarah\\.org$" ];
      allow_room_creation = false;
      allow_legacy_media = false;
      allow_public_room_directory_over_federation = false;
      allow_public_room_directory_without_auth = false;
      allow_public_room_search_by_id = false;
      allow_unlisted_room_search_by_id = false;
      show_all_local_users_in_user_directory = false;
      lockdown_public_room_directory = true;
      require_auth_for_profile_requests = true;
      allow_inbound_profile_lookup_federation_requests = false;

      well_known.client = "https://guest.matrix.odarah.org";
      well_known.livekit_url = "https://rtc.matrix.odarah.org";
      error_on_unknown_config_opts = true;
    };
  };

  systemd.services.tuwunel-remote-media-prune = {
    description = "Prune cached remote media from Tuwunel";
    after = [ "tuwunel.service" ];
    requires = [ "tuwunel.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl kill --kill-whom=main --signal=SIGUSR2 tuwunel.service";
    };
  };

  systemd.timers.tuwunel-remote-media-prune = {
    description = "Daily cached remote media pruning for Tuwunel";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  system.stateVersion = "26.05";
}
