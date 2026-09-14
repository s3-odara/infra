#!/usr/bin/env bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true ]] || {
  echo "cleanup-runner: refusing to run outside GitHub Actions" >&2
  exit 1
}
[[ ${RUNNER_OS:-} == Linux ]] || {
  echo "cleanup-runner: unsupported runner OS: ${RUNNER_OS:-unknown}" >&2
  exit 1
}

echo "::group::Free space before cleanup"
df -h
du -sh /usr/local/lib/android 2>/dev/null || true
echo "::endgroup::"

echo "::group::Cleanup"
sudo rm -rf -- /usr/local/lib/android
echo "::endgroup::"

echo "::group::Free space after cleanup"
df -h
echo "::endgroup::"
