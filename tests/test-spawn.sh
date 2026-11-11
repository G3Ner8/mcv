#!/usr/bin/env bash
#
# Tests for `mcv-herdr.sh spawn`'s git safety, against a fake herdr that does
# the git work for real (tests/fixtures/fake-herdr.sh). Needs bash, git and
# jq; no herdr.
# Run: tests/test-spawn.sh   (exit 0 when every check passes)

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

# A remote with main and a branch someone already pushed, and a clone of it
# whose local branches are only main.
git init -q -b main "$root/seed"
git -C "$root/seed" commit -q --allow-empty -m init
git -C "$root/seed" branch feat/taken
git clone -q --bare "$root/seed" "$root/origin.git"
git clone -q "$root/origin.git" "$root/repo"
repo="$root/repo"
git -C "$repo" config push.default upstream

spawn() { "$H" spawn acme "$@"; }
lower_id() { printf '%s' "$1" | tr '[:upper:]/' '[:lower:]-'; }
locks_empty() { [[ -z "$(ls -A "$MCV_HOME/.locks" 2>/dev/null)" ]]; }

# The fake reproduces what makes the upstream fix necessary: a branch made
# from origin/main gets origin/main as its upstream.
"$HERE/fixtures/fake-herdr.sh" worktree create --cwd "$repo" --branch probe --base origin/main \
  --label probe >/dev/null
expect "fake herdr gives a new branch origin/main as upstream, as herdr does" \
  '[[ "$(git -C "$repo" config branch.probe.merge)" == refs/heads/main ]]'
"$HERE/fixtures/fake-herdr.sh" worktree remove --workspace ws-probe >/dev/null
git -C "$repo" branch -D -q probe

# A normal spawn: worktree on the new branch, from origin/main, no upstream.
out="$(spawn t1 "$repo" fix/one 2>&1)"; rc=$?
expect "spawn succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
wt="$(jq -r .worktree <<<"$out" 2>/dev/null)"
expect "spawn reports base origin/main" '[[ "$(jq -r .base <<<"$out")" == origin/main ]]' "$out"
expect "worker branch has no upstream" \
  '[[ -z "$(git -C "$wt" config branch.fix/one.merge)" && -z "$(git -C "$wt" config branch.fix/one.remote)" ]]'
pushout="$(git -C "$wt" push --dry-run 2>&1)"; prc=$?
expect "a plain git push from the worker (push.default=upstream) does not reach main" \
  '[[ $prc -ne 0 && "$pushout" != *"-> main"* ]]' "rc=$prc $pushout"
expect "lock released after a spawn" 'locks_empty'

# Shared branch names are refused before anything is created.
for b in main master develop; do
  out="$(spawn "s-$b" "$repo" "$b" 2>&1)"; rc=$?
  expect "branch '$b' refused" '[[ $rc -eq 1 && "$out" == *"shared branch"* ]]' "rc=$rc $out"
done

# A branch that exists only on the remote is refused, and nothing is left.
out="$(spawn t2 "$repo" feat/taken 2>&1)"; rc=$?
expect "branch that exists only on origin refused" \
  '[[ $rc -eq 1 && "$out" == *"already exists as remotes/origin/feat/taken"* ]]' "rc=$rc $out"
expect "no local branch made for the refused remote branch" \
  '! git -C "$repo" show-ref --verify --quiet refs/heads/feat/taken'
expect "no task left for the refused spawn" '[[ ! -e "$MCV_HOME/acme/tasks/t2" ]]'
expect "lock released after a refused spawn" 'locks_empty'

# A worktree create that fails half way, after git made the branch, leaves
# no branch behind, so the same spawn can be retried.
out="$(FAKE_FAIL=create spawn t3 "$repo" fix/three 2>&1)"; rc=$?
expect "failed worktree create exits 1" '[[ $rc -eq 1 ]]' "rc=$rc $out"
expect "failed worktree create leaves no branch" \
  '! git -C "$repo" show-ref --verify --quiet refs/heads/fix/three'
expect "lock released after a failed spawn" 'locks_empty'
out="$(spawn t3 "$repo" fix/three 2>&1)"; rc=$?
expect "the same spawn succeeds on retry" '[[ $rc -eq 0 ]]' "rc=$rc $out"

# Names are compared ignoring case. On macOS, once refs are packed, a new
# loose MAIN is the same file as main, and committing to it moves main.
git -C "$repo" pack-refs --all
for b in MAIN Main Develop MASTER FIX/ONE Feat/Taken; do
  out="$(spawn "c-$(lower_id "$b")" "$repo" "$b" 2>&1)"; rc=$?
  expect "branch '$b' refused (same as an existing or shared name, ignoring case)" \
    '[[ $rc -eq 1 && ( "$out" == *"shared branch"* || "$out" == *"already exists as"* ) ]]' "rc=$rc $out"
done
expect "main did not move" '[[ "$(git -C "$repo" rev-parse main)" == "$(git -C "$repo" rev-parse origin/main)" ]]'
for b in origin/fix-x ORIGIN/fix-x refs/heads/fix-x HEAD head/x; do
  out="$(spawn c-ref "$repo" "$b" 2>&1)"; rc=$?
  expect "branch '$b' refused as ambiguous" \
    '[[ $rc -eq 1 && ( "$out" == *"plain name"* || "$out" == *"not a valid branch name"* ) ]]' "rc=$rc $out"
done
out="$(spawn c-new "$repo" Fix/New-Thing 2>&1)"; rc=$?
expect "a new name with capitals is still taken" '[[ $rc -eq 0 ]]' "rc=$rc $out"

# Claude failing to start keeps the task, its worktree and branch for remove.
out="$(FAKE_FAIL=start spawn t4 "$repo" fix/four 2>&1)"; rc=$?
expect "failed agent start exits 1" '[[ $rc -eq 1 ]]' "rc=$rc $out"
expect "failed agent start keeps the task" '[[ -f "$MCV_HOME/acme/tasks/t4/meta" ]]'
expect "failed agent start keeps the branch its worktree holds" \
  'git -C "$repo" show-ref --verify --quiet refs/heads/fix/four'

# Two spawns in one repository run one after the other, and both succeed.
: >"$FAKE_DIR/order"
FAKE_SLEEP=1 spawn p1 "$repo" fix/p1 >"$root/p1.out" 2>&1 & a=$!
FAKE_SLEEP=1 spawn p2 "$repo" fix/p2 >"$root/p2.out" 2>&1 & b=$!
wait "$a"; ra=$?
wait "$b"; rb=$?
expect "parallel spawns both succeed" '[[ $ra -eq 0 && $rb -eq 0 ]]' \
  "$ra $(cat "$root/p1.out") / $rb $(cat "$root/p2.out")"
order="$(cut -d' ' -f1 "$FAKE_DIR/order" | tr '\n' ' ')"
expect "parallel spawns do not overlap in worktree create" \
  '[[ "$order" == "begin end begin end " ]]' "$order"

# A lock left by a spawn that died is taken over.
sleep 0 & dead=$!
wait "$dead"
key="$(printf '%s' "$(git -C "$repo" rev-parse --show-toplevel)" | cksum | cut -d' ' -f1)"
mkdir -p "$MCV_HOME/.locks/$key"
echo "$dead $(( $(date +%s) - 60 ))" >"$MCV_HOME/.locks/$key/pid"
out="$(spawn t5 "$repo" fix/five 2>&1)"; rc=$?
expect "a stale lock is taken over" '[[ $rc -eq 0 ]]' "rc=$rc $out"

# Several spawns that all find the same stale repository lock: one takes it
# over at a time, so their worktree creations never overlap.
overlaps=0
for round in 1 2 3 4 5; do
  mkdir -p "$MCV_HOME/.locks/$key"
  echo "$dead $(( $(date +%s) - 60 ))" >"$MCV_HOME/.locks/$key/pid"
  : >"$FAKE_DIR/order"
  pids=()
  for i in 1 2 3 4 5 6 7 8; do
    FAKE_SLEEP=0.3 spawn "s$round$i" "$repo" "fix/s$round$i" >/dev/null 2>&1 & pids+=($!)
  done
  wait "${pids[@]}"
  order="$(cut -d' ' -f1 "$FAKE_DIR/order" | tr '\n' ' ')"
  [[ "$order" == "$(printf 'begin end %.0s' 1 2 3 4 5 6 7 8)" ]] || overlaps=$((overlaps + 1))
done
expect "8 spawns on a stale repository lock, 5 rounds: worktree creations never overlap" \
  '[[ $overlaps -eq 0 ]]' "$overlaps rounds overlapped"
expect "no repository lock or takeover lock left behind" 'locks_empty'

# A claim left with no pid file (killed between making it and writing the
# pid) blocks that worker name only while it is fresh; the refusal names the
# folder to delete.
mkdir -p "$MCV_HOME/.claims/acme-c1"
out="$(spawn c1 "$repo" fix/c1 2>&1)"; rc=$?
expect "a fresh claim without a pid is refused, naming its folder" \
  '[[ $rc -eq 1 && "$out" == *"$MCV_HOME/.claims/acme-c1"* ]]' "rc=$rc $out"
touch -t 202001010000 "$MCV_HOME/.claims/acme-c1"
out="$(spawn c1 "$repo" fix/c1 2>&1)"; rc=$?
expect "an old claim without a pid is taken over" '[[ $rc -eq 0 ]]' "rc=$rc $out"

# Branch names git or a push would find ambiguous or in conflict are refused
# up front, in one line: a remote's name, a tag's name, and a name that is a
# folder of another branch or holds one (fix and fix/login cannot both exist).
one_line() { [[ $(printf '%s\n' "$out" | wc -l) -eq 1 ]]; }
git -C "$repo" tag v1
for b in origin ORIGIN; do
  out="$(spawn n1 "$repo" "$b" 2>&1)"; rc=$?
  expect "branch '$b' (a remote's name) refused" '[[ $rc -eq 1 && "$out" == *remote* ]] && one_line' "rc=$rc $out"
done
for b in v1 V1; do
  out="$(spawn n2 "$repo" "$b" 2>&1)"; rc=$?
  expect "branch '$b' (a tag's name) refused" '[[ $rc -eq 1 && "$out" == *tag* ]] && one_line' "rc=$rc $out"
done
out="$(spawn n3 "$repo" main/x 2>&1)"; rc=$?
expect "branch main/x (under the branch main) refused" '[[ $rc -eq 1 && "$out" == *"heads/main"* ]] && one_line' "rc=$rc $out"
out="$(spawn n4 "$repo" feat 2>&1)"; rc=$?
expect "branch feat (holding origin's feat/taken) refused" '[[ $rc -eq 1 && "$out" == *"feat/taken"* ]] && one_line' "rc=$rc $out"

# mcv's own options after -- would go to Claude unnoticed.
for o in --base --context; do
  out="$(spawn n5 "$repo" fix/n5 -- "$o" x 2>&1)"; rc=$?
  expect "$o after -- refused" '[[ $rc -eq 1 && "$out" == *"before --"* ]] && one_line' "rc=$rc $out"
done

# --add-dir would open a folder past the context's deny rule, and --settings
# could override MCV_TASK, so neither may reach Claude, in either form.
for o in --add-dir --settings; do
  out="$(spawn n5 "$repo" fix/n5 -- "$o" x 2>&1)"; rc=$?
  expect "$o after -- refused" '[[ $rc -eq 1 && "$out" == *"$o"* && "$out" != *"before --"* ]] && one_line' "rc=$rc $out"
  out="$(spawn n5 "$repo" fix/n5 -- "$o=x" 2>&1)"; rc=$?
  expect "$o=x after -- refused" '[[ $rc -eq 1 && "$out" == *"$o"* && "$out" != *"before --"* ]] && one_line' "rc=$rc $out"
done
out="$(spawn n5 "$repo" fix/n5 -- --permission-mode default --add-dir /tmp 2>&1)"; rc=$?
expect "--add-dir later in the claude args refused" '[[ $rc -eq 1 && "$out" == *"--add-dir"* ]] && one_line' "rc=$rc $out"

# A bare repository has no checkout to make worktrees from.
out="$(spawn n6 "$root/origin.git" fix/n6 2>&1)"; rc=$?
expect "a bare repository is refused as bare" '[[ $rc -eq 1 && "$out" == *bare* ]] && one_line' "rc=$rc $out"

# A context path with glob characters would make the deny rule a pattern
# that misses the folder itself.
mkdir -p "$root/ctx [1]"
out="$(spawn n7 "$repo" fix/n7 --context "$root/ctx [1]" 2>&1)"; rc=$?
expect "a context path with [ ] refused" '[[ $rc -eq 1 && "$out" == *"--context"* ]] && one_line' "rc=$rc $out"
expect "none of these left a task" '[[ -z "$(ls "$MCV_HOME/acme/tasks" | grep "^n[0-9]")" ]]'

# A relative MCV_HOME reaches the worker as an absolute path: the worker
# runs in its worktree, where the relative one would point elsewhere.
out="$(cd "$root" && MCV_HOME=relhome "$H" spawn acme r1 "$repo" fix/r1 2>&1)"; rc=$?
expect "spawn with a relative MCV_HOME succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
expect "the worker's MCV_HOME is absolute" \
  'grep "^agent start acme-r1 " "$FAKE_DIR/calls" | grep -qF "\"MCV_HOME\":\"$root/relhome\""' \
  "$(grep '^agent start acme-r1 ' "$FAKE_DIR/calls")"
expect "the task is kept under the absolute MCV_HOME" '[[ -f "$root/relhome/acme/tasks/r1/meta" ]]'

# A repository whose only remote is not called origin branches from that
# remote's default branch, not quietly from its own HEAD.
git clone -q -o upstream "$root/origin.git" "$root/up"
git -C "$root/up" commit -q --allow-empty -m "local only"
out="$(spawn u1 "$root/up" fix/u1 2>&1)"; rc=$?
expect "only remote 'upstream': base is upstream/main" \
  '[[ $rc -eq 0 && "$(jq -r .base <<<"$out")" == upstream/main ]]' "rc=$rc $out"
git -C "$root/up" remote add mirror "$root/origin.git"
git -C "$root/up" fetch -q mirror
out="$(spawn u2 "$root/up" fix/u2 2>&1)"; rc=$?
expect "several remotes, none origin: refused, asking for --base" \
  '[[ $rc -eq 1 && "$out" == *"--base"* && $(printf "%s\n" "$out" | wc -l) -eq 1 ]]' "rc=$rc $out"

# --existing: a worker on a branch already on the remote, such as an open
# merge request's branch that needs review fixes. Measured on herdr 0.9.5:
# without --base, worktree create quietly makes a new branch of that name
# from HEAD, so spawn must always pass the remote branch as the base.
S="$(cd "$HERE/../bin" && pwd -P)/mcv-status"
one_line() { [[ $rc -eq 1 && $(printf '%s\n' "$out" | wc -l) -eq 1 ]]; }
git clone -q "$root/origin.git" "$root/pusher"
pushed() { # pushed <branch> [<commits>]: a branch on origin, $2 commits past main
  git -C "$root/pusher" switch -q -c "$1" origin/main
  local i
  for ((i = 0; i < ${2:-1}; i++)); do git -C "$root/pusher" commit -q --allow-empty -m "$1 work $i"; done
  git -C "$root/pusher" push -q origin "$1"
  git -C "$root/pusher" rev-parse HEAD
}
mr="$(pushed feat/mr)"
out="$(spawn e1 "$repo" feat/mr --existing 2>&1)"; rc=$?
expect "--existing on a branch only on origin succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
wt="$(jq -r .worktree <<<"$out" 2>/dev/null)"
expect "its worktree is at origin's tip, on the branch itself" \
  '[[ "$(git -C "$wt" rev-parse HEAD)" == "$mr" && "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" == feat/mr ]]'
expect "its upstream is origin/feat/mr, so a plain push and pull reach the merge request" \
  '[[ "$(git -C "$wt" rev-parse --abbrev-ref "@{u}" 2>/dev/null)" == origin/feat/mr ]]'
expect "spawn reports it as existing, based on origin/feat/mr" \
  '[[ "$(jq -r .existing <<<"$out")" == true && "$(jq -r .base <<<"$out")" == origin/feat/mr ]]' "$out"
expect "herdr was given the remote branch as its base" \
  'grep -q "^worktree create .*--branch feat/mr --base origin/feat/mr" "$FAKE_DIR/calls"'
git -C "$wt" commit -q --allow-empty -m "review fix"
pushout="$(git -C "$wt" push --dry-run 2>&1)"; prc=$?
expect "a plain git push goes to feat/mr" '[[ $prc -eq 0 && "$pushout" == *"-> feat/mr"* ]]' "rc=$prc $pushout"
g="$(jq -cn --arg c "git push origin feat/mr" --arg d "$wt" '{tool_input: {command: $c}, cwd: $d}' \
  | MCV_TASK=acme/e1 "$S" --guard-git)"
expect "the git guard lets it push its branch" '[[ -z "$g" ]]' "$g"
c="$(MCV_TASK=acme/e1 "$S" --contract </dev/null | jq -r .hookSpecificOutput.additionalContext)"
expect "its rules say the branch is already on origin: update that merge request, never open another" \
  '[[ "$c" == *"already on origin"* && "$c" == *"never open another"* ]]' "$c"
c="$(MCV_TASK=acme/t1 "$S" --contract </dev/null | jq -r .hookSpecificOutput.additionalContext)"
expect "a worker on a new branch is not told so" '[[ "$c" != *"already on origin"* ]]'

out="$(spawn e2 "$repo" feat/mr --existing 2>&1)"; rc=$?
expect "--existing on a branch another task holds: refused, naming the task" \
  'one_line && [[ "$out" == *"acme/e1"* ]]' "rc=$rc $out"
expect "no task left for it" '[[ ! -e "$MCV_HOME/acme/tasks/e2" ]]'
out="$(spawn e3 "$repo" feat/nowhere --existing 2>&1)"; rc=$?
expect "--existing on a branch origin does not have: refused" \
  'one_line && [[ "$out" == *"not on origin"* ]]' "rc=$rc $out"
expect "no local branch made for it" '! git -C "$repo" show-ref --verify --quiet refs/heads/feat/nowhere'
for b in main develop; do
  out="$(spawn "e-$b" "$repo" "$b" --existing 2>&1)"; rc=$?
  expect "--existing on '$b': refused as a shared branch" 'one_line && [[ "$out" == *"shared branch"* ]]' "rc=$rc $out"
done
git -C "$root/origin.git" symbolic-ref HEAD refs/heads/feat/trunk
pushed feat/trunk >/dev/null
git -C "$repo" fetch -q origin
git -C "$repo" remote set-head origin --auto >/dev/null 2>&1
out="$(spawn e4 "$repo" feat/trunk --existing 2>&1)"; rc=$?
expect "--existing on origin's default branch: refused" \
  'one_line && [[ "$out" == *"default branch"* ]]' "rc=$rc $out"
git -C "$root/origin.git" symbolic-ref HEAD refs/heads/main
git -C "$repo" remote set-head origin --auto >/dev/null 2>&1
pushed feat/mr2 >/dev/null
out="$(spawn e5 "$repo" feat/mr2 --existing --base origin/main 2>&1)"; rc=$?
expect "--existing with --base: refused" 'one_line && [[ "$out" == *"--base"* ]]' "rc=$rc $out"

# A local branch of that name: one behind origin (a branch an earlier worker
# left) is brought up to origin and used; one with commits origin lacks, or
# one checked out somewhere, is refused, since the worker would lose or
# fight over that work.
git -C "$repo" fetch -q origin
git -C "$repo" branch -q feat/mr2 origin/main
mr2="$(git -C "$repo" rev-parse origin/feat/mr2)"
out="$(spawn e6 "$repo" feat/mr2 --existing 2>&1)"; rc=$?
expect "--existing with a local branch behind origin succeeds" '[[ $rc -eq 0 ]]' "rc=$rc $out"
wt6="$(jq -r .worktree <<<"$out" 2>/dev/null)"
expect "that worktree is at origin's tip, upstream origin/feat/mr2" \
  '[[ "$(git -C "$wt6" rev-parse HEAD)" == "$mr2" && "$(git -C "$wt6" rev-parse --abbrev-ref "@{u}" 2>/dev/null)" == origin/feat/mr2 ]]'
pushed feat/mr3 >/dev/null
git -C "$repo" fetch -q origin
git -C "$repo" branch -q feat/mr3 origin/feat/mr3
git -C "$repo" switch -q feat/mr3
git -C "$repo" commit -q --allow-empty -m "local only"
git -C "$repo" switch -q main
out="$(spawn e7 "$repo" feat/mr3 --existing 2>&1)"; rc=$?
expect "--existing with a local branch ahead of origin: refused" \
  'one_line && [[ "$out" == *"commits origin/feat/mr3 lacks"* ]]' "rc=$rc $out"
expect "that local branch is untouched" \
  '[[ "$(git -C "$repo" log -1 --format=%s feat/mr3)" == "local only" ]]'
pushed feat/mr4 >/dev/null
git -C "$repo" fetch -q origin
git -C "$repo" switch -q -c feat/mr4 origin/feat/mr4
out="$(spawn e8 "$repo" feat/mr4 --existing 2>&1)"; rc=$?
git -C "$repo" switch -q main
expect "--existing on a branch checked out in the main checkout: refused" \
  'one_line && [[ "$out" == *"checked out"* ]]' "rc=$rc $out"

# A spawn that fails deletes the local branch only when it made it.
pushed feat/mr5 >/dev/null
out="$(FAKE_FAIL=create spawn e9 "$repo" feat/mr5 --existing 2>&1)"; rc=$?
expect "a failed --existing spawn leaves no local branch it made" \
  '[[ $rc -eq 1 ]] && ! git -C "$repo" show-ref --verify --quiet refs/heads/feat/mr5' "rc=$rc $out"
git -C "$repo" fetch -q origin
git -C "$repo" branch -q feat/mr5 origin/feat/mr5
out="$(FAKE_FAIL=create spawn e10 "$repo" feat/mr5 --existing 2>&1)"; rc=$?
expect "a failed --existing spawn keeps a local branch that was already there" \
  '[[ $rc -eq 1 ]] && git -C "$repo" show-ref --verify --quiet refs/heads/feat/mr5' "rc=$rc $out"

out="$("$H" remove acme/e1 2>&1)"; rc=$?
expect "remove keeps the branch of an --existing worker" \
  '[[ $rc -eq 0 && "$(jq -r .branch_kept <<<"$out")" == feat/mr ]]' "rc=$rc $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
