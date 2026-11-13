#!/usr/bin/env bash
#
# Run every tests/test-*.sh, or the ones named, and report each file's
# result. Exit 0 only when every file passes.
# Run: tests/run.sh                 all tests
#      tests/run.sh test-hooks.sh   one file

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$HERE" || exit 1

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  files=(test-*.sh)
fi

# The refs of the checkout the tests sit in, before and after: no test may
# commit, branch, tag or stash there (test-isolation.sh says how it happened).
refs() { git -C "$HERE/.." for-each-ref 2>/dev/null || true; }
refs_before="$(refs)"

failed=()
for t in "${files[@]}"; do
  if out="$(bash "$t" 2>&1)"; then
    printf 'pass  %-22s %s\n' "$t" "$(tail -1 <<<"$out")"
  else
    printf 'FAIL  %-22s %s\n' "$t" "$(tail -1 <<<"$out")"
    grep '^FAIL' <<<"$out" | sed 's/^/      /'
    failed+=("$t")
  fi
done

if [[ "$(refs)" != "$refs_before" ]]; then
  printf '\nFAIL  the tests changed this checkout'"'"'s refs:\n'
  diff <(printf '%s\n' "$refs_before") <(refs) | sed 's/^/      /'
  exit 1
fi

if (( ${#failed[@]} )); then
  printf '\n%d of %d files failed: %s\n' "${#failed[@]}" "${#files[@]}" "${failed[*]}"
  exit 1
fi
printf '\nall %d files passed\n' "${#files[@]}"
