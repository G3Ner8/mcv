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
# herdr may report a worker at the trust question as blocked rather than
# idle; with no rules yet, the refusal still points at that question.
out="$(FAKE_AGENT_STATE=blocked "$H" prompt acme/t4 "hello" --no-wait 2>&1)"; rc=$?
expect "a blocked worker without rules is refused with the trust hint" \
  '[[ $rc -eq 1 && "$out" == *blocked* && "$out" == *trust* ]]' "rc=$rc $out"
# herdr's newer code for a Claude that has exited reads like the others.
out="$(FAKE_FAIL=notrunning "$H" prompt acme/t2 "hello" --no-wait 2>&1)"; rc=$?
expect "agent_not_running explains the worker is not running Claude" \
  '[[ $rc -eq 1 && "$out" == *"not running Claude any more"* ]]' "rc=$rc $out"

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
# worktree, the task goes, the branch stays (it holds a commit).
wt="$(jq -r .worktree "$(meta acme t1)")"
ws="$(jq -r .workspace_id "$(meta acme t1)")"
git -C "$wt" commit -q --allow-empty -m "worker's work"
rm -f "$FAKE_DIR/ws/$ws"
out="$("$H" remove acme/t1 2>&1)"; rc=$?
expect "remove works after the workspace was closed" '[[ $rc -eq 0 ]]' "rc=$rc $out"
expect "its worktree folder is gone" '[[ ! -d "$wt" ]]'
expect "git no longer lists the worktree" '! git -C "$repo" worktree list | grep -qF "$wt"'
expect "its task state is gone" '[[ ! -e "$MCV_HOME/acme/tasks/t1" ]]'
expect "its branch, which holds a commit, is kept" \
  '[[ "$(jq -r .branch_kept <<<"$out")" == fix/t1 ]] && git -C "$repo" show-ref --verify --quiet refs/heads/fix/t1' "$out"

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

# remove leaves no empty folders of its own behind: the project's tasks
# folder once its last task is gone, and herdr's per-repository worktree
# folder once its last worktree is. A folder that still holds something
# stays, and so does the project's folder, which keeps its journal and history.
out="$(FAKE_DIR="$root/fake2" "$H" spawn solo s1 "$repo" fix/s1 2>&1)"; rc=$?
wt="$(jq -r .worktree "$(meta solo s1)")"
expect "spawn solo/s1 succeeds" '[[ $rc -eq 0 && -d "$wt" ]]' "rc=$rc $out"
j="$MCV_HOME/solo/journal.log"
expect "the journal has a line for the spawn" \
  'awk -F"\t" "\$2 == \"spawn\" && \$3 == \"solo/s1\" && \$4 ~ /^ok/" "$j" | grep -q .' "$(cat "$j" 2>&1)"
FAKE_DIR="$root/fake2" "$H" spawn solo s1 "$repo" fix/s1-again >/dev/null 2>&1
expect "a refused command is in the journal with its reason" \
  'awk -F"\t" "\$2 == \"spawn\" && \$4 ~ /^error: task solo\/s1 already exists/" "$j" | grep -q .' "$(cat "$j" 2>&1)"
MCV_TASK=solo/s1 "$HERE/../bin/mcv-status" note "half way" >/dev/null
out="$(FAKE_DIR="$root/fake2" "$H" remove solo/s1 2>&1)"; rc=$?
expect "remove of a project's last task succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
expect "the project's empty tasks folder is gone" '[[ ! -e "$MCV_HOME/solo/tasks" ]]'
expect "herdr's empty per-repository folder is gone" '[[ ! -e "$(dirname "$wt")" ]]'
hist="$(ls -d "$MCV_HOME"/solo/history/s1-* 2>/dev/null | head -1)"
expect "remove keeps the task's meta in its history" '[[ -n "$hist" && "$(jq -r .branch "$hist/meta" 2>/dev/null)" == fix/s1 ]]' "$hist"
expect "the history keeps the status log" 'grep -q "half way" "$hist/status.log" 2>/dev/null'
expect "the history keeps the worker's transcript path" \
  'grep -qx "$root/fake2/transcripts/solo-s1.jsonl" "$hist/transcripts" 2>/dev/null' "$(cat "$hist/transcripts" 2>&1)"
expect "the journal names where the history went" \
  'awk -F"\t" "\$2 == \"remove\" && \$3 == \"solo/s1\"" "$j" | grep -qF "$hist"' "$(cat "$j" 2>&1)"
expect "remove's output names the history folder" '[[ "$(jq -r .history <<<"$out" 2>/dev/null)" == "$hist" ]]' "$out"

# The coordinator adds its own lines to the journal; a worker cannot.
S="$HERE/../bin/mcv-status"
out="$("$S" --journal solo "watcher restarted after 30 minutes" 2>&1)"; rc=$?
expect "--journal adds a coordinator note" \
  '[[ $rc -eq 0 ]] && awk -F"\t" "\$2 == \"note\" && \$3 == \"-\" && \$4 == \"watcher restarted after 30 minutes\"" "$j" | grep -q .' "rc=$rc $out"
out="$("$S" --journal solo/s1 "worker needed the API path" 2>&1)"; rc=$?
expect "--journal with a task names it" \
  '[[ $rc -eq 0 ]] && awk -F"\t" "\$2 == \"note\" && \$3 == \"solo/s1\"" "$j" | grep -q .' "rc=$rc $out"
out="$(MCV_TASK=solo/s1 "$S" --journal solo "x" 2>&1)"; rc=$?
expect "--journal refused for a worker" '[[ $rc -eq 1 && "$out" == *worker* ]]' "rc=$rc $out"
for bad_p in "../x" "Solo" ""; do
  out="$("$S" --journal "$bad_p" "x" 2>&1)"; rc=$?
  expect "--journal refuses project '$bad_p'" '[[ $rc -ne 0 && ! -e "$MCV_HOME/x" ]]' "rc=$rc $out"
done
out="$("$S" --journal solo "" 2>&1)"; rc=$?
expect "--journal refuses empty text" '[[ $rc -eq 2 ]]' "rc=$rc $out"
expect "another project's state is untouched" '[[ -d "$MCV_HOME/acme/tasks" ]]'
out="$("$H" spawn solo s2 "$repo" fix/s2 2>&1)"
wt="$(jq -r .worktree "$(meta solo s2)")"
"$H" remove solo/s2 >/dev/null 2>&1
expect "herdr's folder that still holds other worktrees stays" '[[ -d "$(dirname "$wt")" ]]'

# A failed start says what the pane shows: herdr types the claude command
# at the shell prompt, and something the shell asked first can take it.
export FAKE_DIR="$root/fake3"
out="$(FAKE_FAIL=start FAKE_SCREEN=$'$ \nWould you like to update? [Y/n] c\nzsh: command not found: laude\n\n' \
  "$H" spawn solo f1 "$repo" fix/f1 2>&1)"; rc=$?
expect "a failed start is one line naming herdr's error and the pane's last lines" \
  '[[ $rc -eq 1 && $(printf "%s\n" "$out" | wc -l) -eq 1 && "$out" == *"claude did not start; its pane shows: "*"update? [Y/n] c / zsh: command not found: laude" ]]' "rc=$rc $out"
expect "the journal has the pane's lines too" 'grep -qF "command not found: laude" "$j"' "$(tail -2 "$j")"
"$H" remove solo/f1 >/dev/null 2>&1

# remove deletes a branch that never moved from its base, has no upstream
# and is on no remote: it holds no work, and would block a new spawn of the
# same name. Any other branch is kept.
out="$("$H" spawn solo b1 "$repo" fix/b1 2>&1)"
out="$("$H" remove solo/b1 2>&1)"; rc=$?
expect "remove deletes a branch with no commits past its base" \
  '[[ $rc -eq 0 && "$(jq -r .branch_deleted <<<"$out")" == fix/b1 ]] && ! git -C "$repo" show-ref --verify --quiet refs/heads/fix/b1' "rc=$rc $out"
expect "the journal says the branch was deleted" 'tail -1 "$j" | grep -qF "branch fix/b1 deleted (no commits past its base)"' "$(tail -1 "$j")"
# (A new id: the fake herdr keeps every agent name it started.)
out="$("$H" spawn solo b1b "$repo" fix/b1 2>&1)"; rc=$?
expect "the same branch name can be spawned again" '[[ $rc -eq 0 ]]' "rc=$rc $out"
git -C "$repo" config branch.fix/b1.remote origin
git -C "$repo" config branch.fix/b1.merge refs/heads/fix/b1
out="$("$H" remove solo/b1b 2>&1)"; rc=$?
expect "a branch with an upstream is kept, commits or not" \
  '[[ $rc -eq 0 && "$(jq -r .branch_kept <<<"$out")" == fix/b1 ]]' "rc=$rc $out"
git -C "$repo" branch -D -q fix/b1
"$H" spawn solo b2 "$repo" fix/b2 >/dev/null 2>&1
git -C "$repo" update-ref refs/remotes/origin/fix/b2 HEAD
out="$("$H" remove solo/b2 2>&1)"; rc=$?
expect "a branch a remote has is kept" '[[ $rc -eq 0 && "$(jq -r .branch_kept <<<"$out")" == fix/b2 ]]' "rc=$rc $out"
"$H" spawn solo b3 "$repo" fix/b3 >/dev/null 2>&1
jq 'del(.base_sha)' "$(meta solo b3)" >"$root/m" && mv "$root/m" "$(meta solo b3)"
out="$("$H" remove solo/b3 2>&1)"; rc=$?
expect "a task from before 0.2.1 (no base commit) keeps its branch" \
  '[[ $rc -eq 0 && "$(jq -r .branch_kept <<<"$out")" == fix/b3 ]]' "rc=$rc $out"

# The worker's workspace is labelled as mcv's in herdr's sidebar.
"$H" spawn solo l1 "$repo" fix/l1 >/dev/null 2>&1
expect "the worker's workspace label is 'mcv solo/l1'" \
  'herdr workspace list | jq -e ".result.workspaces[] | select(.label == \"mcv solo/l1\")" >/dev/null'
"$H" remove solo/l1 >/dev/null 2>&1

# herdr opens a workspace for the repository's main checkout when it has none
# open. The last remove in the repository closes the one a spawn opened, if
# it is still as herdr opened it; one the user had open is never closed.
export FAKE_DIR="$root/fake4"
mainws() { herdr workspace list | jq -r '.result.workspaces[] | select(.worktree.is_linked_worktree == false) | .workspace_id'; }
"$H" spawn solo w1 "$repo" fix/w1 >/dev/null 2>&1
"$H" spawn solo w2 "$repo" fix/w2 >/dev/null 2>&1
expect "spawn made herdr open the repository's workspace" '[[ -n "$(mainws)" ]]' "$(mainws)"
out="$("$H" remove solo/w1 2>&1)"
expect "it stays while another worker of the repository is open" \
  '[[ -n "$(mainws)" && "$(jq -r ".closed_workspace // empty" <<<"$out")" == "" ]]' "$out"
out="$("$H" remove solo/w2 2>&1)"
expect "the last remove closes it and says so" \
  '[[ -z "$(mainws)" && "$(jq -r .closed_workspace <<<"$out")" == ws-main-repo ]]' "$out"
expect "the journal names the closed workspace" 'tail -1 "$j" | grep -qF "closed repository workspace ws-main-repo"' "$(tail -1 "$j")"
"$H" spawn solo w3 "$repo" fix/w3 >/dev/null 2>&1
out="$(FAKE_MAIN_BUSY=1 "$H" remove solo/w3 2>&1)"
expect "one with a program running in its shell stays open" '[[ -n "$(mainws)" ]]' "$out"
"$H" spawn solo w4 "$repo" fix/w4 >/dev/null 2>&1
out="$(FAKE_MAIN_PANES=2 "$H" remove solo/w4 2>&1)"
expect "one the user split into more panes stays open" '[[ -n "$(mainws)" ]]' "$out"
"$H" spawn solo w5 "$repo" fix/w5 >/dev/null 2>&1
out="$("$H" remove solo/w5 2>&1)"
expect "once it is idle again, a later remove closes it" '[[ -z "$(mainws)" ]]' "$out"
export FAKE_DIR="$root/fake5"
"$H" spawn solo w6 "$repo" fix/w6 >/dev/null 2>&1
herdr workspace close ws-main-repo >/dev/null
out="$("$H" remove solo/w6 2>&1)"; rc=$?
expect "one the user closed already is fine" '[[ $rc -eq 0 && "$(jq -r ".closed_workspace // empty" <<<"$out")" == "" ]]' "rc=$rc $out"
export FAKE_DIR="$root/fake6"
out="$(FAKE_MAIN_OPEN="$repo" "$H" spawn solo w7 "$repo" fix/w7 2>&1)"
out="$("$H" remove solo/w7 2>&1)"
expect "the user's own repository workspace is never closed" '[[ -n "$(mainws)" ]]' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
