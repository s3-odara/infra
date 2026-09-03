#!/usr/bin/env bash
set -euo pipefail

work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT

auth_header=$work_directory/auth-header
page_file=$work_directory/page.json
violations_file=$work_directory/violations.jsonl
: >"$violations_file"

api_key=$(SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops decrypt \
  --extract '["ct_search_api_key"]' "$CT_MONITOR_SECRET_FILE")
printf 'Authorization: Bearer %s\n' "$api_key" >"$auth_header"
unset api_key

if [[ -s $CT_MONITOR_CURSOR_FILE ]]; then
  cursor=$(<"$CT_MONITOR_CURSOR_FILE")
else
  cursor=$CT_MONITOR_INITIAL_CURSOR
fi
[[ -n $cursor ]]

after=$cursor
latest=$cursor
while true; do
  curl --silent --show-error --fail --max-time 30 \
    --header "@$auth_header" \
    --get 'https://api.certspotter.com/v1/issuances' \
    --data-urlencode 'domain=odarah.org' \
    --data-urlencode 'include_subdomains=true' \
    --data-urlencode 'match_wildcards=true' \
    --data-urlencode 'expand=dns_names' \
    --data-urlencode 'expand=issuer' \
    --data-urlencode 'expand=issuer.caa_domains' \
    --data-urlencode "after=$after" \
    >"$page_file"

  jq -e '
    type == "array" and
    all(.[ ];
      (.id | type == "string" and length > 0) and
      (.pubkey_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.dns_names | type == "array" and all(.[ ]; type == "string")) and
      (.issuer | type == "object") and
      (
        .issuer.caa_domains == null or
        (.issuer.caa_domains | type == "array" and all(.[ ]; type == "string"))
      )
    )
  ' "$page_file" >/dev/null

  count=$(jq 'length' "$page_file")
  ((count > 0)) || break

  latest=$(jq -r 'last.id' "$page_file")
  [[ $latest != "$after" ]]

  jq -c --slurpfile policies "$CT_MONITOR_POLICY_FILE" '
    def canonical_names:
      map(ascii_downcase | rtrimstr(".")) | unique | sort;

    $policies[0] as $policy |
    .[] as $issuance |
    ($issuance.dns_names | canonical_names) as $dns_names |
    (($issuance.issuer.caa_domains // []) | map(ascii_downcase | rtrimstr("."))) as $issuer_domains |
    ([
      $policy.certificates[] |
      select(
        .pubkeySha256 == $issuance.pubkey_sha256 and
        (.dnsNames | canonical_names) == $dns_names
      )
    ] | length > 0) as $certificate_expected |
    ($issuer_domains | index("letsencrypt.org") != null) as $issuer_expected |
    select(($certificate_expected and $issuer_expected) | not) |
    {
      id: $issuance.id,
      pubkey_sha256: $issuance.pubkey_sha256,
      dns_names: $dns_names,
      issuer: ($issuance.issuer.friendly_name // $issuance.issuer.name // "unknown"),
      issuer_caa_domains: $issuer_domains,
      not_before: ($issuance.not_before // "unknown"),
      not_after: ($issuance.not_after // "unknown"),
      reasons: ([
        if $certificate_expected then empty else "unexpected SPKI or SAN profile" end,
        if $issuer_expected then empty else "unexpected issuer" end
      ])
    }
  ' "$page_file" >>"$violations_file"

  after=$latest
done

if [[ -s $violations_file ]]; then
  echo "Unexpected Certificate Transparency issuance(s):" >&2
  cat "$violations_file" >&2

  topic=$(SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops decrypt \
    --extract '["ntfy_topic"]' "$CT_MONITOR_SECRET_FILE")
  encoded_topic=$(jq -rn --arg topic "$topic" '$topic | @uri')
  http_status=$(curl --silent --show-error --output /dev/null --max-time 15 \
    --write-out '%{http_code}' \
    --header "Title: Certificate Transparency warning: $(hostname --short)" \
    --header 'Priority: 5' \
    --header 'Tags: warning' \
    --data-binary 'odarah.orgで想定外の証明書発行を検出しました。' \
    "https://ntfy.sh/$encoded_topic")
  [[ $http_status =~ ^2[0-9]{2}$ ]]
  exit 0
fi

cursor_temporary=$CT_MONITOR_CURSOR_FILE.tmp
printf '%s\n' "$latest" >"$cursor_temporary"
mv "$cursor_temporary" "$CT_MONITOR_CURSOR_FILE"
