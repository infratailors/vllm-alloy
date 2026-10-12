#!/usr/bin/env bash
# The GitLab mirror ended with the uni.lu mirror obligation (webapp ADR-0009,
# 30 September 2026). Fail if any workflow pushes to or mentions GitLab again.
# Run: bash tests/test_no_gitlab.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
hits="$(grep -rniI 'gitlab' "${ROOT}/.github" 2>/dev/null)"
if [[ -n "${hits}" ]]; then
  echo "FAIL no workflow references GitLab:"
  echo "${hits}"
  exit 1
fi
echo "ok   no workflow references GitLab"
