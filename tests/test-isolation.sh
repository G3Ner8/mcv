#!/usr/bin/env bash
#
# Tests that the other test files leave the repository they are run from
# alone, even when the code under test is broken. Three empty commits made
# by a test reached this repository's history, one of them a release: a
# failed spawn left a worktree path empty, and `git -C ""` runs in the
# current folder, which was the checkout the suite was started from.
#
# Each test file is run from inside a scratch repository, against a copy of
# bin/ whose mcv-herdr.sh always fails; the scratch repository must come out
# as it went in. Needs bash, git and jq.
# Run: tests/test-isolation.sh   (exit 0 when every check passes)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
cd "$root" || exit 1

# A copy of what the tests read, with a spawn that cannot work.
mkdir "$root/copy"
for d in bin hooks skills tests .claude-plugin; do
  [[ -e "$HERE/../$d" ]] && cp -R "$HERE/../$d" "$root/copy/$d"
done
printf '#!/usr/bin/env bash\necho "mcv-herdr: broken on purpose" >&2\nexit 1\n' >"$root/copy/bin/mcv-herdr.sh"
chmod +x "$root/copy/bin/mcv-herdr.sh"

# The checkout a developer would be standing in: a commit, a tracked file
# with an uncommitted change, and an untracked file.
work="$root/work"
git init -q -b feat/mine "$work"
echo one >"$work/tracked"
git -C "$work" add tracked
git -C "$work" -c user.name=dev -c user.email=dev@example.com commit -q -m "feat: mine"
echo two >>"$work/tracked"
echo new >"$work/untracked"

# Everything a stray git command could change: refs, the index and working
# tree, the stash, the configuration.
state() {
  git -C "$work" for-each-ref
  git -C "$work" status --porcelain
  git -C "$work" stash list
  git -C "$work" config --local --list
  cat "$work/tracked" "$work/untracked"
}
before="$(state)"

for t in "$root"/copy/tests/test-*.sh; do
  name="$(basename "$t")"
  [[ "$name" != test-isolation.sh ]] || continue
  ( cd "$work" && bash "$t" ) >/dev/null 2>&1
  after="$(state)"
  expect "$name leaves the checkout it is run from alone when spawn is broken" \
    '[[ "$after" == "$before" ]]' "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -8)"
  before="$after"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
