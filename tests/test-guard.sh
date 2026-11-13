#!/usr/bin/env bash
#
# Tests for mcv-status --guard-git, the PreToolUse hook on Bash that stops a
# worker's git commands that reach past its own branch: a push to another
# branch, a force-push, deleting or moving another branch or a tag. It is fed
# the JSON Claude Code gives a PreToolUse hook (tool_input.command and cwd,
# measured with Claude Code 2.1). Needs bash, git and jq.
# Run: tests/test-guard.sh   (exit 0 when every check passes)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
S="$(cd "$HERE/../bin" && pwd -P)/mcv-status"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
# Work from the temporary folder: a git command given an empty path runs in
# the current folder, which must never be the checkout this was started from.
cd "$root" || exit 1
export MCV_HOME="$root/home" GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$MCV_HOME/acme/tasks/t1"
echo '{"branch":"fix/cart"}' >"$MCV_HOME/acme/tasks/t1/meta"
git init -q -b fix/cart "$root/wt"
git init -q -b main "$root/other"

# Print the hook's decision for a command run in folder $2 (default the
# worker's worktree): "deny: <reason>", or "allow" when it says nothing.
decide() {
  local out
  out="$(jq -cn --arg c "$1" --arg d "${2:-$root/wt}" \
      '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' \
    | MCV_TASK="${TASK-acme/t1}" "$S" --guard-git 2>&1)"
  if [[ -z "$out" ]]; then echo allow; return; fi
  if [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" == deny ]]; then
    printf 'deny: %s\n' "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")"
  else
    printf 'other: %s\n' "$out"
  fi
}
allows() { local r; r="$(decide "$@")"; expect "allows: $1" '[[ "$r" == allow ]]' "$r"; }
denies() { local r; r="$(decide "$@")"; expect "denies: $1" '[[ "$r" == deny:* ]]' "$r"; }

# Ordinary work on its own branch.
allows 'git status'
allows 'git commit -m "fix: add oat-milk surcharge"'
allows 'git push'
allows 'git push -u origin fix/cart'
allows 'git push origin HEAD'
allows 'git push origin HEAD:fix/cart'
allows 'git push origin fix/cart:refs/heads/fix/cart'
allows 'git push --force-with-lease origin fix/cart'
allows 'git push --force-with-lease=fix/cart origin fix/cart'
allows 'git -C . push origin fix/cart'
allows 'npm test && git push -u origin fix/cart'
allows 'git rebase origin/main'
allows 'git branch'
allows 'git branch -a'
allows 'git tag'
allows 'git tag v-local'
allows 'git checkout -b scratch'
allows 'git log --oneline | head'
allows 'echo "git push --force"'
allows 'grep -r "git push origin main" docs'
# Redirections are not refspecs (measured on carsol: "this pushes to 2>").
allows 'git push -u origin fix/cart 2>&1'
allows 'git push -u origin fix/cart 2>&1 | tail -5'
allows 'git push -u origin fix/cart >/tmp/push.log 2>&1'
allows 'git push -u origin fix/cart 2> /tmp/err.txt'
allows 'git push -u origin fix/cart &>/tmp/push.log'
allows 'git push origin fix/cart >>/tmp/push.log'
allows 'git push 2>&1'
allows 'git push -u origin fix/cart 2>/dev/null'
allows 'git push -u origin fix/cart </dev/null'

# Pushes that reach another branch, or force.
denies 'git push origin main'
denies 'git push origin develop'
denies 'git push origin HEAD:develop'
denies 'git push origin fix/cart:main'
denies 'git push origin fix/cart main'
denies 'git push origin refs/heads/fix/cart:refs/heads/main'
denies 'git push origin v1.0'
denies 'git push origin refs/tags/v1.0'
denies 'git push --force origin fix/cart'
denies 'git push -f origin fix/cart'
denies 'git push -uf origin fix/cart'
denies 'git push origin +fix/cart'
denies 'git push --force-with-lease origin main'
denies 'git push --all origin'
denies 'git push --mirror origin'
denies 'git push --tags origin'
denies 'git push --prune origin'
denies 'git push --delete origin main'
denies 'git push -d origin main'
denies 'git push origin :main'
denies 'npm test && git push origin main'
denies 'npm test; git push -f'
# A redirection does not hide the real target.
denies 'git push origin main 2>&1'
denies 'git push origin develop >/tmp/push.log 2>&1'
denies 'git push 2>/dev/null origin main'
denies 'git push -f origin fix/cart 2>&1'
denies 'cd /tmp && git push origin main'
denies 'git -c push.default=current push origin main'
denies '/usr/bin/git push origin main'
denies 'GIT_TRACE=1 git push origin main'
denies 'echo ok | git push origin main'
denies "git push origin 'main'"
denies 'git push -o ci.skip origin main'

# A plain push, or HEAD, from another branch pushes that branch.
git -C "$root/other" commit -q --allow-empty -m init 2>/dev/null \
  || GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
     git -C "$root/other" commit -q --allow-empty -m init
denies 'git push' "$root/other"
denies 'git push origin HEAD' "$root/other"
denies "git -C $root/other push"
allows "git -C $root/other push origin fix/cart"

# Deleting or moving other branches and tags.
denies 'git branch -D main'
denies 'git branch -d develop'
denies 'git branch --delete feat/x'
denies 'git branch -m fix/other'
denies 'git branch -M main'
denies 'git branch -f main HEAD'
denies 'git branch --force develop origin/develop'
denies 'git tag -d v1.0'
denies 'git tag --delete v1.0'
denies 'git tag -f v1.0'
denies 'git update-ref refs/heads/main HEAD'
denies 'git update-ref -d refs/tags/v1.0'
denies 'git checkout -B main'
denies 'git switch -C develop'
allows 'git branch -dr origin/old'
allows 'git update-ref refs/heads/fix/cart HEAD'
allows 'git checkout -B fix/cart origin/fix/cart'

# Short options written together: the letter that matters is found among
# the others (a sampled mutation run changed these checks and nothing here
# noticed).
denies 'git tag -af v1.0 -m "again"'
denies 'git tag -fa v1.0'
denies 'git tag -ad v1.0'
allows 'git tag -a v2.0 -m "release"'
allows 'git tag -l'
denies 'git branch -vf main HEAD'
denies 'git branch -fv develop origin/develop'
denies 'git branch -qD main'
denies 'git branch -qm fix/other'
allows 'git branch -vv'
allows 'git branch -qf fix/cart HEAD'
denies 'git push -ud origin main'
denies 'git push -qd origin main'
denies 'git push -uq origin main'
allows 'git push -uq origin fix/cart'
allows 'git push -qd origin fix/cart'
r="$(decide 'git push -qd origin main')"
expect "a delete among short options is called a delete" '[[ "$r" == *"deletes main"* ]]' "$r"
# The folder comes from the hook's input; without one, the hook's own.
r="$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "git push"}}' \
  | (cd "$root/other" && MCV_TASK=acme/t1 "$S" --guard-git 2>&1))"
expect "no cwd in the input: the push is judged from the hook's own folder" '[[ "$r" == *"deny"*"main"* ]]' "$r"

# What the guard does not see, written down so that a change to it is a
# decision. It reads the command's words and catches a slip, not a worker
# set on getting round it. None of these forms was used in 3755 Bash calls
# of 60 real workers (88 pushes), so they are recorded here, not chased.
allows 'if npm test; then git push origin main; fi'
allows 'for r in a b; do git push origin main; done'
allows 'timeout 60 git push origin main'
allows 'time git push origin main'
allows 'xargs git push origin main'
allows 'bash -c "git push origin main"'
allows $'git push \\\n  origin main'
# Not written in the command, so refused rather than guessed.
denies 'git push origin "$(git branch --show-current)"'
denies 'git push -u origin "$BRANCH"'
# Commands that reach other worktrees without naming a branch are outside
# it too: the stash is one list for the whole repository.
allows 'git stash drop'
allows 'git worktree remove --force ../other'

# The reason names the worker's branch and how to ask instead.
r="$(decide 'git push origin main')"
expect "the reason names the worker's own branch" '[[ "$r" == *fix/cart* ]]' "$r"
expect "the reason points to needs-decision" '[[ "$r" == *needs-decision* ]]' "$r"

# Not a worker, or a task that does not exist: says nothing.
r="$(TASK='' decide 'git push -f origin main')"
expect "without MCV_TASK: allow" '[[ "$r" == allow ]]' "$r"
r="$(TASK=acme/gone decide 'git push -f origin main')"
expect "with MCV_TASK naming no task: allow" '[[ "$r" == allow ]]' "$r"
out="$(printf 'not json' | MCV_TASK=acme/t1 "$S" --guard-git 2>&1)"; rc=$?
expect "input that is not JSON: silent, exit 0" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
