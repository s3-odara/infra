# Shared JST maintenance window so monthly backups, daily backups, GC,
# upgrades, pruning, Btrfs balance, and storage checks stay ordered without overlap.
{
  monthly = {
    tuwunelBackup = {
      calendar = "*-*-01 02:15:00 Asia/Tokyo";
      delay = "3m";
    };
    prosodyBackup = {
      calendar = "*-*-01 02:30:00 Asia/Tokyo";
      delay = "3m";
    };
    knotBackup = {
      calendar = "*-*-01 02:45:00 Asia/Tokyo";
      delay = "3m";
    };
    radicaleBackup = {
      calendar = "*-*-01 02:50:00 Asia/Tokyo";
      delay = "3m";
    };
  };

  daily = {
    tuwunelOnlineBackup = {
      calendar = "*-*-* 03:00:00 Asia/Tokyo";
      delay = "3m";
    };
    prosodyBackup = {
      calendar = "*-*-* 03:15:00 Asia/Tokyo";
      delay = "3m";
    };
    knotBackup = {
      calendar = "*-*-* 03:30:00 Asia/Tokyo";
      delay = "3m";
    };
    matrixBotBackup = {
      calendar = "*-*-* 03:45:00 Asia/Tokyo";
      delay = "3m";
    };
    radicaleBackup = {
      calendar = "*-*-* 03:50:00 Asia/Tokyo";
      delay = "3m";
    };
    nixGc = {
      calendar = "*-*-* 04:00:00 Asia/Tokyo";
      delay = "15m";
    };
    hostUpgrade = {
      calendar = "*-*-* 04:20:00 Asia/Tokyo";
      delay = "3m";
    };
    guestUpgrade = {
      calendar = "*-*-* 04:35:00 Asia/Tokyo";
      delay = "15m";
    };
    guestJournalVacuum = {
      calendar = "*-*-* 05:05:00 Asia/Tokyo";
      delay = "3m";
    };
    tuwunelMediaPrune = {
      calendar = "*-*-* 05:15:00 Asia/Tokyo";
      delay = "3m";
    };
    nixStoreDedup = {
      calendar = "*-*-* 05:20:00 Asia/Tokyo";
      delay = "3m";
    };
    btrfsBalance = {
      calendar = "*-*-* 05:40:00 Asia/Tokyo";
      delay = "5m";
    };
    hostStorageMonitor = {
      calendar = "*-*-* 06:00:00 Asia/Tokyo";
      delay = "1h";
    };
  };
}
