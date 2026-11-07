#!/usr/bin/env bash
#
# Tests for the task lifecycle in mcv-herdr.sh (task names, spawn's starting
# marker, prompt to a worker whose Claude has exited, remove after the user
# closed the workspace), against tests/fixtures/fake-herdr.sh. Needs bash,
# git and jq; no herdr.
# Run: tests/test-lifecycle.sh   (exit 0 when every check passes)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
H="$(cd "$HERE/../bin" && pwd -P)/mcv-herdr.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
ln -s "$HERE/fixtures/fake-herdr.sh" "$root/bin/herdr"
export PATH="$root/bin:$PATH" HERDR_ENV=1 MCV_HOME="$root/home" FAKE_DIR="$root/fake"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q -b main "$root/repo"
git -C "$root/repo" commit -q --allow-empty -m init
repo="$root/repo"
meta() { printf '%s' "$MCV_HOME/$1/tasks/$2/meta"; }

# A task id never reaches the file system unchecked: "../" in it would let
# remove delete a folder outside mcv's state.
mkdir -p "$root/victim"
echo '{"worktree":"/nonexistent","workspace_id":"x","branch":"b"}' >"$root/victim/meta"
mkdir -p "$MCV_HOME/acme/tasks"
for t in "acme/../../../victim" "acme/.." "acme/a/b" "../acme/x" "Acme/x"; do
  out="$("$H" remove "$t" 2>&1)"; rc=$?
  expect "remove refuses task '$t'" '[[ $rc -eq 1 && "$out" == *"expected <project>/<id>"* ]]' "rc=$rc $out"
done
expect "the folder outside mcv's state is untouched" '[[ -f "$root/victim/meta" ]]'
out="$("$H" read "acme/../x" 2>&1)"; rc=$?
expect "read refuses a task with ../" '[[ $rc -eq 1 ]]' "rc=$rc $out"

# A successful spawn leaves no starting marker; a failed start keeps it.
out="$("$H" spawn acme t1 "$repo" fix/t1 2>&1)"; rc=$?
expect "spawn succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
expect "a started worker has no starting marker" '[[ ! -e "$MCV_HOME/acme/tasks/t1/starting" ]]'
out="$(FAKE_FAIL=start "$H" spawn acme t2 "$repo" fix/t2 2>&1)"; rc=$?
expect "a worker that failed to start keeps its starting marker" \
  '[[ $rc -eq 1 && -e "$MCV_HOME/acme/tasks/t2/starting" ]]' "rc=$rc $out"

# Worker names: <project>-<id> must not repeat across projects, nor match an
# agent herdr already runs.
out="$("$H" spawn a-b c "$repo" fix/abc 2>&1)"; rc=$?
expect "spawn a-b/c succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
out="$("$H" spawn a b-c "$repo" fix/abc2 2>&1)"; rc=$?
expect "spawn a/b-c refused: same worker name as a-b/c" \
  '[[ $rc -eq 1 && "$out" == *"taken by task a-b/c"* ]]' "rc=$rc $out"
echo "zeta-x" >>"$FAKE_DIR/agents"
out="$("$H" spawn zeta x "$repo" fix/zx 2>&1)"; rc=$?
expect "spawn refused when herdr already runs an agent of that name" \
  '[[ $rc -eq 1 && "$out" == *"already has an agent"* ]]' "rc=$rc $out"

# prompt to a worker whose Claude has exited says so in plain words.
out="$(FAKE_FAIL=notready "$H" prompt acme/t1 "hello" --no-wait 2>&1)"; rc=$?
expect "prompt to an exited worker herdr still lists explains it" \
  '[[ $rc -eq 1 && "$out" == *"not running Claude any more"* ]]' "rc=$rc $out"
out="$("$H" prompt acme/t2 "hello" --no-wait 2>&1)"; rc=$?
expect "prompt to a worker herdr does not know explains it" \
  '[[ $rc -eq 1 && "$out" == *"not running Claude any more"* ]]' "rc=$rc $out"
# read goes to the pane, which stays readable after Claude exits.
out="$("$H" read acme/t2 2>&1)"; rc=$?
expect "read reads the worker's pane, agent or not" \
  '[[ $rc -eq 0 && "$out" == "screen of $(jq -r .pane_id "$(meta acme t2)")" ]]' "rc=$rc $out"
# A worker that failed to start and was then let through takes a prompt,
# which clears its marker.
echo "acme-t2" >>"$FAKE_DIR/agents"
MCV_TASK=acme/t2 "$(dirname "$H")/mcv-status" --contract >/dev/null
out="$("$H" prompt acme/t2 "hello" --no-wait 2>&1)"; rc=$?
expect "prompt to a worker let through after a failed start succeeds" \
  '[[ $rc -eq 0 && "$out" == *working* ]]' "rc=$rc $out"
expect "that prompt clears the starting marker" '[[ ! -e "$MCV_HOME/acme/tasks/t2/starting" ]]'

# A worker whose Claude did not load mcv's hooks (the plugin is not installed
# for it) has none of the worker rules: prompt refuses to give it work.
out="$("$H" spawn acme t3 "$repo" fix/t3 2>&1)"; rc=$?
expect "a worker with mcv's hooks has the rules-loaded marker" \
  '[[ $rc -eq 0 && -f "$MCV_HOME/acme/tasks/t3/rules-loaded" ]]' "rc=$rc $out"
out="$(FAKE_NOHOOKS=1 "$H" spawn acme t4 "$repo" fix/t4 2>&1)"; rc=$?
expect "spawn of a worker without hooks still succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
out="$("$H" prompt acme/t4 "hello" --no-wait 2>&1)"; rc=$?
expect "prompt refuses a worker that never got mcv's rules" \
  '[[ $rc -eq 1 && "$out" == *"has no mcv worker rules yet"* && $(printf "%s\n" "$out" | wc -l) -eq 1 ]]' "rc=$rc $out"
expect "that refusal names the trust dialog first, as the usual cause" \
  '[[ "$out" == *"trust"*"plugin is not loaded"* ]]' "$out"
expect "that refused prompt sent nothing" '! grep -q "^agent prompt acme-t4" "$FAKE_DIR/calls"'

# prompt with no text: an option where the text should be, or empty text,
# is refused rather than sent (and then waited on for 10 minutes).
for args in "--no-wait" "--timeout 5000" "" "   "; do
  if [[ "$args" == --* ]]; then
    # shellcheck disable=SC2086
    out="$("$H" prompt acme/t3 $args 2>&1)"; rc=$?
  else
    out="$("$H" prompt acme/t3 "$args" --no-wait 2>&1)"; rc=$?
  fi
  expect "prompt with text '$args' refused" '[[ $rc -eq 1 && "$out" == *text* ]]' "rc=$rc $out"
done
expect "none of them was sent" '! grep -q "^agent prompt acme-t3" "$FAKE_DIR/calls"'

# remove refuses a worker that is working or at a dialog: its tree can be
# clean for a moment while it still works.
for s in working blocked; do
  out="$(FAKE_AGENT_STATE=$s "$H" remove acme/t3 2>&1)"; rc=$?
  expect "remove refuses a $s worker" '[[ $rc -eq 1 && "$out" == *"$s"* && -f "$(meta acme t3)" ]]' "rc=$rc $out"
done
out="$("$H" remove acme/t3 2>&1)"; rc=$?
expect "remove takes the same worker once it is idle" '[[ $rc -eq 0 ]]' "rc=$rc $out"

# remove after the user closed the worker's workspace: git removes the
# worktree, the task goes, the branch stays.
wt="$(jq -r .worktree "$(meta acme t1)")"
ws="$(jq -r .workspace_id "$(meta acme t1)")"
rm -f "$FAKE_DIR/ws/$ws"
out="$("$H" remove acme/t1 2>&1)"; rc=$?
expect "remove works after the workspace was closed" '[[ $rc -eq 0 ]]' "rc=$rc $out"
expect "its worktree folder is gone" '[[ ! -d "$wt" ]]'
expect "git no longer lists the worktree" '! git -C "$repo" worktree list | grep -qF "$wt"'
expect "its task state is gone" '[[ ! -e "$MCV_HOME/acme/tasks/t1" ]]'
expect "its branch is kept" 'git -C "$repo" show-ref --verify --quiet refs/heads/fix/t1'

# remove when the worktree folder was deleted by hand as well.
wt="$(jq -r .worktree "$(meta acme t2)")"
ws="$(jq -r .workspace_id "$(meta acme t2)")"
rm -f "$FAKE_DIR/ws/$ws"
rm -rf "$wt"
out="$("$H" remove acme/t2 2>&1)"; rc=$?
expect "remove works when the worktree folder is already gone" '[[ $rc -eq 0 ]]' "rc=$rc $out"
expect "git's record of that worktree is pruned" '! git -C "$repo" worktree list | grep -qF "$wt"'

# remove still refuses a dirty worktree when herdr no longer knows it.
wt="$(jq -r .worktree "$(meta a-b c)")"
ws="$(jq -r .workspace_id "$(meta a-b c)")"
rm -f "$FAKE_DIR/ws/$ws"
echo x >"$wt/new-file"
out="$("$H" remove a-b/c 2>&1)"; rc=$?
expect "remove refuses a dirty worktree" '[[ $rc -eq 1 && "$out" == *uncommitted* && -f "$wt/new-file" ]]' "rc=$rc $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
