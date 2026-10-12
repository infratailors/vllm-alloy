#!/usr/bin/env bash
# The uni.lu GitLab mirror obligation ended on 30 September 2026 (webapp
# ADR-0010); the webapp and its dashboard dropped their mirrors (ADR-0014), and
# so did this repo. Fail if GitLab CI or a workflow mentioning GitLab returns.
# Run: bash tests/test_no_gitlab.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

if [[ -e "${ROOT}/.gitlab-ci.yml" ]]; then
  echo "FAIL no .gitlab-ci.yml"
  failures=$((failures + 1))
else
  echo "ok   no .gitlab-ci.yml"
fi

# .github/ may be absent (there is no workflow today); that is a pass.
hits=""
if [[ -d "${ROOT}/.github" ]]; then
  hits="$(grep -rniI 'gitlab' "${ROOT}/.github")"
fi
if [[ -n "${hits}" ]]; then
  echo "FAIL no workflow references GitLab:"
  echo "${hits}"
  failures=$((failures + 1))
else
  echo "ok   no workflow references GitLab"
fi

exit "${failures}"
