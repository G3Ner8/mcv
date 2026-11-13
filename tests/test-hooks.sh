#!/usr/bin/env bash
#
# Tests for hooks/hooks.json: every hook does nothing unless MCV_TASK names a
# task (a hook runs in every session where the plugin is installed), and does
# its job when it does. The commands are taken from hooks.json itself and run
# the way Claude Code runs them, through a shell with CLAUDE_PLUGIN_ROOT set.
# Needs bash and jq.
# Run: tests/test-hooks.sh   (exit 0 when every check passes)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
HOOKS="$ROOT/hooks/hooks.json"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT
# Work from the temporary folder: a git command given an empty path runs in
# the current folder, which must never be the checkout this was started from.
cd "$home" || exit 1

expect "hooks.json exists and parses" 'jq -e . "$HOOKS" >/dev/null 2>&1'
expect "only SessionStart and PreToolUse hooks" \
  '[[ "$(jq -r ".hooks | keys | join(\" \")" "$HOOKS" 2>/dev/null)" == "PreToolUse SessionStart" ]]'
expect "SessionStart has no matcher, so it runs on every source" \
  '[[ "$(jq -r ".hooks.SessionStart[0].matcher // \"none\"" "$HOOKS" 2>/dev/null)" == none ]]'
expect "PreToolUse matches AskUserQuestion, then Bash" \
  '[[ "$(jq -r "[.hooks.PreToolUse[].matcher] | join(\" \")" "$HOOKS" 2>/dev/null)" == "AskUserQuestion Bash" ]]'

session_cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS" 2>/dev/null)"
pre_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS" 2>/dev/null)"
bash_cmd="$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$HOOKS" 2>/dev/null)"
run() { env CLAUDE_PLUGIN_ROOT="$ROOT" MCV_HOME="$home" "$@"; }
push_main='{"tool_name":"Bash","cwd":"/","tool_input":{"command":"git push --force origin main"}}'

# Unset: silent, exit 0, nothing written. The Bash hook gets a command it
# would refuse for a worker.
for name in SessionStart PreToolUse Bash; do
  cmd="$session_cmd"; [[ $name == PreToolUse ]] && cmd="$pre_cmd"
  if [[ $name == Bash ]]; then
    out="$(run env -u MCV_TASK sh -c "$bash_cmd" <<<"$push_main" 2>&1)"; rc=$?
    expect "Bash without MCV_TASK: silent, exit 0" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
    out="$(run MCV_TASK= sh -c "$bash_cmd" <<<"$push_main" 2>&1)"; rc=$?
    expect "Bash with MCV_TASK empty: silent, exit 0" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
    continue
  fi
  out="$(run env -u MCV_TASK sh -c "$cmd" </dev/null 2>&1)"; rc=$?
  expect "$name without MCV_TASK: exit 0" '[[ $rc -eq 0 ]]' "rc=$rc"
  expect "$name without MCV_TASK: no output" '[[ -z "$out" ]]' "$out"
  out="$(run MCV_TASK= sh -c "$cmd" </dev/null 2>&1)"; rc=$?
  expect "$name with MCV_TASK empty: silent, exit 0" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
done
expect "no state written by unset hooks" '[[ -z "$(ls -A "$home")" ]]'

# Set, but to no task spawn created: still silent.
for t in acme/t1 garbage; do
  out="$(run MCV_TASK="$t" sh -c "$session_cmd; $pre_cmd" </dev/null 2>&1)"; rc=$?
  expect "hooks with MCV_TASK '$t' and no task: silent, exit 0" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
  out="$(run MCV_TASK="$t" sh -c "$bash_cmd" <<<"$push_main" 2>&1)"; rc=$?
  expect "Bash hook with MCV_TASK '$t' and no task: silent, exit 0" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
done
expect "no state written for a task that does not exist" '[[ -z "$(ls -A "$home")" ]]'

# Set to a task: the hooks do their job.
mkdir -p "$home/acme/tasks/t1"
echo '{"branch":"fix/x"}' >"$home/acme/tasks/t1/meta"
out="$(run MCV_TASK=acme/t1 sh -c "$session_cmd" </dev/null)"
expect "SessionStart with MCV_TASK: worker rules as SessionStart context" \
  '[[ "$(jq -r .hookSpecificOutput.hookEventName <<<"$out" 2>/dev/null)" == SessionStart ]]' "$out"
out="$(run MCV_TASK=acme/t1 sh -c "$pre_cmd" </dev/null)"
expect "PreToolUse with MCV_TASK: deny" \
  '[[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out" 2>/dev/null)" == deny ]]' "$out"
out="$(run MCV_TASK=acme/t1 sh -c "$bash_cmd" <<<"$push_main")"
expect "Bash with MCV_TASK: a force-push to main is denied" \
  '[[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out" 2>/dev/null)" == deny ]]' "$out"
out="$(run MCV_TASK=acme/t1 sh -c "$bash_cmd" <<<'{"tool_name":"Bash","cwd":"/","tool_input":{"command":"ls"}}')"
expect "Bash with MCV_TASK: an ordinary command passes silently" '[[ -z "$out" ]]' "$out"

# SessionStart keeps the path of each session's transcript, once, for the
# task's history; Claude gives it in the hook's input.
for src in startup resume startup; do
  n=1; [[ $src == resume ]] && n=2
  run MCV_TASK=acme/t1 sh -c "$session_cmd" >/dev/null \
    <<<"{\"hook_event_name\":\"SessionStart\",\"source\":\"$src\",\"transcript_path\":\"/x/s$n.jsonl\"}"
done
want="$(printf '/x/s1.jsonl\n/x/s2.jsonl')"
got="$(cat "$home/acme/tasks/t1/transcripts" 2>/dev/null)"
expect "SessionStart records each transcript path once" '[[ "$got" == "$want" ]]' "$got"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
