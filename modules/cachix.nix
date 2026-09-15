{
  nix.settings = {
    extra-substituters = [ "https://s3-odara.cachix.org" ];
    extra-trusted-public-keys = [
      "s3-odara.cachix.org-1:eghgfpDCkVI80Zg01X97Q795Y29YPXovtLvB2ZAT1Lg="
    ];
  };
}
