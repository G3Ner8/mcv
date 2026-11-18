#!/usr/bin/env bash
#
# Tests for bin/mcv-status. Needs bash, jq; no herdr.
# Run: tests/test-status.sh   (exit 0 when every check passes)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="$(cd "$HERE/../bin" && pwd -P)"
S="$BIN/mcv-status"

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
log="$home/shop/tasks/t1/status.log"

# Without MCV_TASK: worker kinds refuse, hook outputs stay silent.
out="$(env -u MCV_TASK MCV_HOME="$home" "$S" note hi 2>&1)"; rc=$?
expect "worker kind without MCV_TASK exits 2" '[[ $rc -eq 2 ]]' "rc=$rc"
expect "worker kind without MCV_TASK says so" '[[ "$out" == *"MCV_TASK not set"* ]]' "$out"
out="$(env -u MCV_TASK MCV_HOME="$home" "$S" --contract 2>&1)"; rc=$?
expect "--contract without MCV_TASK: exit 0, no output" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc out=$out"
out="$(env -u MCV_TASK MCV_HOME="$home" "$S" --deny-ask 2>&1)"; rc=$?
expect "--deny-ask without MCV_TASK: exit 0, no output" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc out=$out"
expect "nothing written without MCV_TASK" '[[ -z "$(ls -A "$home")" ]]'

export MCV_HOME="$home" MCV_TASK=shop/t1

# A task that does not exist (no meta) is not a worker: kinds refuse, hooks
# stay silent, nothing is written.
out="$("$S" note hi 2>&1)"; rc=$?
expect "worker kind for a task with no meta exits 1" '[[ $rc -eq 1 && "$out" == *"no task"* ]]' "rc=$rc $out"
for t in shop/t1 garbage "shop/../x" "SHOP/t1" "shop/t1/x"; do
  out="$(MCV_TASK="$t" "$S" --contract 2>&1)$(MCV_TASK="$t" "$S" --deny-ask 2>&1)"; rc=$?
  expect "hooks silent for MCV_TASK '$t' with no task behind it" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
done
expect "nothing written for a task with no meta" '[[ -z "$(ls -A "$home")" ]]'

# The task as spawn leaves it.
mkdir -p "$home/shop/tasks/t1"
echo '{}' >"$home/shop/tasks/t1/meta"

# Question numbering.
q1="$("$S" needs-decision "Which login flow?")"
q2="$("$S" needs-decision "Keep the old route?")"
expect "first question is q1" '[[ "$q1" == q1 ]]' "got '$q1'"
expect "second question is q2" '[[ "$q2" == q2 ]]' "got '$q2'"

# Other kinds print nothing and append one line each.
out="$("$S" note "halfway")"
expect "note prints nothing" '[[ -z "$out" ]]' "$out"
"$S" blocked "cannot reach the database" >/dev/null
"$S" "done" "login fixed" >/dev/null
"$S" failed "tests will not run" >/dev/null
expect "six lines written" '[[ $(wc -l <"$log") -eq 6 ]]' "$(cat "$log")"

# Line format: four tab-separated fields, timestamp first.
first="$(head -1 "$log")"
expect "line has four fields" '[[ $(awk -F"\t" "{print NF}" <<<"$first") -eq 4 ]]' "$first"
expect "first field is a UTC timestamp" '[[ "$first" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"'"'\t'"'"' ]]' "$first"
expect "question line carries kind and id" '[[ "$(cut -f2,3 <<<"$first")" == "needs-decision"$'"'"'\t'"'"'q1 ]]' "$first"
expect "non-question line has - for id" '[[ "$(sed -n 3p "$log" | cut -f2,3)" == "note"$'"'"'\t'"'"'- ]]' "$(sed -n 3p "$log")"

# Tabs and newlines in text are folded so one event stays one line.
"$S" note "$(printf 'a\tb\nc\r\nd')" >/dev/null
last="$(tail -1 "$log")"
expect "folded text keeps four fields" '[[ $(awk -F"\t" "{print NF}" <<<"$last") -eq 4 ]]' "$last"
expect "folded text is on one line" '[[ $(wc -l <"$log") -eq 7 ]]'

# Unknown kind and malformed MCV_TASK.
"$S" shout hi >/dev/null 2>&1; rc=$?
expect "unknown kind exits 2" '[[ $rc -eq 2 ]]' "rc=$rc"
MCV_TASK=noslash "$S" note hi >/dev/null 2>&1; rc=$?
expect "malformed MCV_TASK exits 1" '[[ $rc -eq 1 ]]' "rc=$rc"

# The coordinator closes a question.
env -u MCV_TASK "$S" --task shop/t1 answered q1 "use the new flow"; rc=$?
expect "answering q1 succeeds" '[[ $rc -eq 0 ]]' "rc=$rc"
expect "answer line recorded" '[[ "$(tail -1 "$log" | cut -f2,3)" == "answered"$'"'"'\t'"'"'q1 ]]' "$(tail -1 "$log")"
env -u MCV_TASK "$S" --task shop/t1 answered q1 "again" >/dev/null 2>&1; rc=$?
expect "answering q1 twice exits 1" '[[ $rc -eq 1 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t1 answered q9 "nope" >/dev/null 2>&1; rc=$?
expect "answering an unasked question exits 1" '[[ $rc -eq 1 ]]' "rc=$rc"

# An answer the coordinator could not send yet (the worker was busy) is kept
# as pending, so the watcher can hand it back when the worker stops.
"$S" --task shop/t1 pending q2 "keep it" >/dev/null 2>&1; rc=$?
expect "a worker cannot record a pending answer" '[[ $rc -eq 1 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t1 pending q2 "keep the old route"; rc=$?
expect "pending q2 succeeds" '[[ $rc -eq 0 ]]' "rc=$rc"
expect "pending line recorded with its text" \
  '[[ "$(tail -1 "$log" | cut -f2-4)" == "pending"$'"'"'\t'"'"'"q2"$'"'"'\t'"'"'"keep the old route" ]]' "$(tail -1 "$log")"
env -u MCV_TASK "$S" --task shop/t1 pending q1 "late" >/dev/null 2>&1; rc=$?
expect "pending for an answered question exits 1" '[[ $rc -eq 1 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t1 pending q9 "nope" >/dev/null 2>&1; rc=$?
expect "pending for an unasked question exits 1" '[[ $rc -eq 1 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t1 answered q2 "keep the old route"; rc=$?
expect "a pending question can still be answered" '[[ $rc -eq 0 ]]' "rc=$rc"

# Text given without quotes arrives whole, not cut to its first word.
"$S" note halfway through the cart >/dev/null
expect "unquoted report text is kept whole" '[[ "$(tail -1 "$log" | cut -f4)" == "halfway through the cart" ]]' "$(tail -1 "$log")"
q="$("$S" needs-decision Per drink or per order?)"
env -u MCV_TASK "$S" --task shop/t1 answered "$q" per drink >/dev/null; rc=$?
expect "unquoted answer text is kept whole" \
  '[[ $rc -eq 0 && "$(tail -1 "$log" | cut -f2-4)" == "answered"$'"'"'\t'"'"'"$q"$'"'"'\t'"'"'"per drink" ]]' "rc=$rc $(tail -1 "$log")"

# Empty text says nothing: refused as a usage error, nothing written.
n_before=$(wc -l <"$log")
for t in "" "   "; do
  "$S" "done" "$t" >/dev/null 2>&1; rc=$?
  expect "report with text '$t' refused" '[[ $rc -eq 2 ]]' "rc=$rc"
done
q="$("$S" needs-decision "Oat or soy?")"
env -u MCV_TASK "$S" --task shop/t1 answered "$q" "" >/dev/null 2>&1; rc=$?
expect "an empty answer refused" '[[ $rc -eq 2 ]]' "rc=$rc"
expect "only the question was written" '[[ $(wc -l <"$log") -eq $((n_before + 1)) ]]' "$(tail -2 "$log")"
env -u MCV_TASK "$S" --task shop/t1 answered "$q" "oat" >/dev/null

# Text that is only escape sequences is empty once they are removed.
"$S" needs-decision $'\e[31m\e[0m' >/dev/null 2>&1; rc=$?
expect "a question of only escape sequences refused" '[[ $rc -eq 2 ]]' "rc=$rc"

# Terminal escape sequences are removed whole, not left as "[31m".
"$S" note $'\e[31mred\e[0m plain \e]0;title\a end' >/dev/null
expect "escape sequences removed whole" '[[ "$(tail -1 "$log" | cut -f4)" == "red plain  end" ]]' "$(tail -1 "$log" | cut -f4 | od -c | head -3)"

# CSI with a private-parameter prefix (> or ?) and a charset designation such
# as ESC ( B leave nothing behind either.
"$S" note $'a\e[>4;1mb\e[?25lc\e(Bd\e)0e\e7f' >/dev/null
expect "private CSI and charset designations removed whole" '[[ "$(tail -1 "$log" | cut -f4)" == "abcdef" ]]' "$(tail -1 "$log" | cut -f4 | od -c | head -3)"

# The C1 CSI introducer U+009B (UTF-8 C2 9B) starts a sequence too. Thai
# U+0E1B ends in the byte 9B and must survive.
"$S" note $'\xe0\xb8\x9bx\xc2\x9b31my\xc2\x9b?25hz\xc2\x9b' >/dev/null
expect "C1 CSI sequences removed whole" '[[ "$(tail -1 "$log" | cut -f4)" == $'"'"'\xe0\xb8\x9bxyz'"'"' ]]' "$(tail -1 "$log" | cut -f4 | od -c | head -3)"

# Hook outputs with MCV_TASK set.
c="$("$S" --contract)"
expect "--contract marks that the worker got its rules" '[[ -f "$home/shop/tasks/t1/rules-loaded" ]]'
expect "--contract is JSON" 'jq -e . <<<"$c" >/dev/null'
expect "--contract is a SessionStart context" \
  '[[ "$(jq -r .hookSpecificOutput.hookEventName <<<"$c")" == SessionStart ]]'
ctx="$(jq -r .hookSpecificOutput.additionalContext <<<"$c")"
expect "contract names the task" '[[ "$ctx" == *"shop/t1"* ]]'
expect "contract gives the absolute mcv-status path" '[[ "$ctx" == *"$S"* ]]'
expect "contract forbids AskUserQuestion" '[[ "$ctx" == *"AskUserQuestion"* ]]'
expect "contract says to end the turn" '[[ "$ctx" == *"end your turn"* ]]'
expect "contract asks for one decision per question" '[[ "$ctx" == *"One decision per needs-decision"* ]]'
expect "contract asks for waiting before a turn ends on background work" \
  '[[ "$ctx" == *"\"$S\" waiting"* && "$ctx" == *"end a turn to wait for background work"*"run waiting first"* ]]'
expect "contract no longer asks for a note before such a turn end" \
  '[[ "$ctx" != *"note saying what you are waiting for"* ]]'
expect "contract says notes wake nobody and should be rare" \
  '[[ "$ctx" == *"note"*"wakes nobody"* ]]'
expect "contract keeps AskUserQuestion off even when the user types directly" \
  '[[ "$ctx" == *"outranks the coordinator. Even then"*"never AskUserQuestion"* ]]'
expect "contract with no branch in meta names none" '[[ "$ctx" == *"the branch you started on"* ]]'
expect "contract forbids force-push" '[[ "$ctx" == *"Never force-push"* ]]'
expect "contract defers to project git rules" '[[ "$ctx" == *"they win"* ]]'
printf '{"branch":"fix/login"}\n' >"$home/shop/tasks/t1/meta"
ctx="$("$S" --contract | jq -r .hookSpecificOutput.additionalContext)"
expect "contract names the worker's branch from meta" '[[ "$ctx" == *"Work only on \`fix/login\`"* ]]'

expect "contract without context has no context rule" '[[ "$ctx" != *"opened for you to read"* ]]'

# With a context: a read-only rule, and ../ explained when the repo sits in it.
mkdir -p "$home/proj/app"
proj="$(cd "$home/proj" && pwd -P)"
printf '{"branch":"fix/login","context":"%s","repo":"%s/app"}\n' "$proj" "$proj" >"$home/shop/tasks/t1/meta"
ctx="$("$S" --contract | jq -r .hookSpecificOutput.additionalContext)"
expect "contract names the context folder as read-only" \
  '[[ "$ctx" == *"$proj is the project around this repository"*"Never write, move or delete anything there"* ]]' "$ctx"
expect "contract maps ../ to the context when the repo sits in it" \
  '[[ "$ctx" == *"may use ../<path>; from this worktree that means $proj/<path>"* ]]' "$ctx"
printf '{"branch":"fix/login","context":"%s","repo":"/elsewhere/app"}\n' "$proj" >"$home/shop/tasks/t1/meta"
ctx="$("$S" --contract | jq -r .hookSpecificOutput.additionalContext)"
expect "no ../ line when the repo is not directly in the context" \
  '[[ "$ctx" == *"opened for you to read"* && "$ctx" != *"may use ../"* ]]' "$ctx"
printf '{"branch":"fix/login"}\n' >"$home/shop/tasks/t1/meta"

d="$("$S" --deny-ask)"
expect "--deny-ask is JSON" 'jq -e . <<<"$d" >/dev/null'
expect "--deny-ask denies" '[[ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$d")" == deny ]]'
reason="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$d")"
expect "deny reason gives the mcv-status path" '[[ "$reason" == *"$S"* ]]'
expect "deny reason names needs-decision" '[[ "$reason" == *"needs-decision"* ]]'

# Question ids are q<n>, matched literally: no regex, no forged lines.
for q in "q." "q1.*" "$(printf 'q1\nanswered')" "x1" "q0"; do
  env -u MCV_TASK "$S" --task shop/t1 answered "$q" "x" >/dev/null 2>&1; rc=$?
  expect "answered refuses question id '$(printf '%s' "$q" | tr '\n' ' ')'" '[[ $rc -eq 1 ]]' "rc=$rc"
done
expect "no forged line in the log" '! grep -q "^answered" "$log"'

# Concurrent writers: question numbers never repeat, a question is answered
# once, long lines never interleave.
mkdir -p "$home/shop/tasks/t2"
echo '{}' >"$home/shop/tasks/t2/meta"
log2="$home/shop/tasks/t2/status.log"
for i in $(seq 1 20); do MCV_TASK=shop/t2 "$S" needs-decision "question $i" >"$home/q$i" & done
wait
ids="$(cat "$home"/q* | sort | uniq | wc -l | tr -d ' ')"
expect "20 concurrent questions get 20 different ids" '[[ "$ids" -eq 20 ]]' "$(cat "$home"/q* | sort | tr '\n' ' ')"
rm -f "$home"/q*
for i in $(seq 1 5); do env -u MCV_TASK "$S" --task shop/t2 answered q3 "answer $i" >/dev/null 2>&1 & done
wait
expect "5 concurrent answers to one question: one recorded" \
  '[[ "$(cut -f2,3 "$log2" | grep -c "^answered"$'"'"'\t'"'"'"q3$")" -eq 1 ]]'
big="$(printf 'x%.0s' $(seq 1 20000))"
for i in $(seq 1 8); do MCV_TASK=shop/t2 "$S" note "$i$big" & done
wait
expect "8 concurrent 20 KB lines: each line whole" \
  '[[ "$(awk -F"\t" "NF == 4 && \$2 == \"note\" && \$4 ~ /^[1-8]x+\$/ && length(\$4) == 20001" "$log2" | wc -l | tr -d " ")" -eq 8 ]]'
expect "no lock left behind" '[[ ! -e "$log2.lock" ]]'

# A lock left by a writer that died is taken over.
sleep 0 & dead=$!
wait "$dead"
mkdir "$log2.lock" && echo "$dead $(( $(date +%s) - 60 ))" >"$log2.lock/pid"
MCV_TASK=shop/t2 "$S" note "after a stale lock" >/dev/null 2>&1; rc=$?
expect "a stale lock is taken over" '[[ $rc -eq 0 && "$(tail -1 "$log2")" == *"after a stale lock" ]]' "rc=$rc"

# Several writers that all find the same stale lock: exactly one takes it
# over at a time, so question ids still never repeat. Taking over was check,
# then delete, so a second writer could delete the lock the first had just
# made, and both wrote at once.
mkdir -p "$home/shop/tasks/t4"
echo '{}' >"$home/shop/tasks/t4/meta"
log4="$home/shop/tasks/t4/status.log"
dupes=0
for round in $(seq 1 25); do
  mkdir "$log4.lock" && echo "$dead $(( $(date +%s) - 60 ))" >"$log4.lock/pid"
  for i in $(seq 1 12); do MCV_TASK=shop/t4 "$S" needs-decision "round $round question $i" >"$home/r$i" 2>/dev/null & done
  wait
  [[ "$(cat "$home"/r* | sort | uniq -d)" == "" ]] || dupes=$((dupes + 1))
  rm -f "$home"/r*
done
expect "12 writers on a stale lock, 25 rounds: no question id repeats" '[[ $dupes -eq 0 ]]' "$dupes rounds had repeats"
expect "every question was written" '[[ "$(cut -f2 "$log4" | grep -cx needs-decision)" -eq 300 ]]' "$(cut -f2 "$log4" | grep -cx needs-decision)"
expect "no lock or takeover lock left behind" '[[ ! -e "$log4.lock" && ! -e "$log4.lock.takeover" ]]'

# A lock just taken (under 2 seconds old) is never taken over, even when its
# pid has exited: that pid may have just released it to another writer.
mkdir "$log2.lock" && echo "$dead $(date +%s)" >"$log2.lock/pid"
( sleep 1; echo "released by holder" >>"$log2"; rm -rf "$log2.lock" ) &
MCV_TASK=shop/t2 "$S" note "after a fresh lock" >/dev/null 2>&1; rc=$?
wait
expect "a fresh lock is waited for, not taken over" \
  '[[ $rc -eq 0 && "$(tail -2 "$log2" | head -1)" == "released by holder" && "$(tail -1 "$log2")" == *"after a fresh lock" ]]' \
  "rc=$rc $(tail -2 "$log2")"

# A log that ends mid-line (a writer killed, an old log) gets its newline
# back before the next line, so a question never hides inside another line.
mkdir -p "$home/shop/tasks/t3"
echo '{}' >"$home/shop/tasks/t3/meta"
log3="$home/shop/tasks/t3/status.log"
printf '2026-01-01T00:00:00Z\tnote\t-\tcut off' >"$log3"
q="$(MCV_TASK=shop/t3 "$S" needs-decision "after a cut line")"
expect "after a cut-off line: the question is q1 on its own line" \
  '[[ "$q" == q1 && "$(tail -1 "$log3" | cut -f2,3)" == "needs-decision"$'"'"'\t'"'"'q1 ]]' "$(cat "$log3")"
env -u MCV_TASK "$S" --task shop/t3 answered q1 "ok" >/dev/null 2>&1; rc=$?
expect "and it can be answered" '[[ $rc -eq 0 ]]' "rc=$rc"

# Control characters other than tab and newline never reach the log.
MCV_TASK=shop/t3 "$S" note "$(printf 'a\033[31mred\033[0m\007b')" >/dev/null
last="$(tail -1 "$log3")"
expect "escape and bell characters are removed" '[[ "$last" == *$'"'"'\t'"'"'"aredb" ]]' "$(printf '%q' "$last")"
MCV_TASK=shop/t3 "$S" note "สวัสดี ✓" >/dev/null
expect "Thai and other UTF-8 text is kept" '[[ "$(tail -1 "$log3")" == *"สวัสดี ✓" ]]'

# waiting is a worker kind like note: one line, no id, text required.
out="$(MCV_TASK=shop/t3 "$S" waiting "qa pair, about 15 minutes")"; rc=$?
expect "waiting prints nothing and succeeds" '[[ $rc -eq 0 && -z "$out" ]]' "rc=$rc $out"
expect "waiting is logged with no id" \
  '[[ "$(tail -1 "$log3" | cut -f2-4)" == "waiting"$'"'"'\t'"'"'"-"$'"'"'\t'"'"'"qa pair, about 15 minutes" ]]' "$(tail -1 "$log3")"
MCV_TASK=shop/t3 "$S" waiting >/dev/null 2>&1; rc=$?
expect "waiting without text is refused" '[[ $rc -eq 2 ]]' "rc=$rc"

# A worker cannot close a question; only the coordinator records answers.
MCV_TASK=shop/t3 "$S" needs-decision "mine" >/dev/null
out="$(MCV_TASK=shop/t3 "$S" --task shop/t3 answered q2 "self" 2>&1)"; rc=$?
expect "--task with MCV_TASK set is refused" '[[ $rc -eq 1 && "$out" == *"only the coordinator"* ]]' "rc=$rc $out"
expect "the question stays open" '! cut -f2,3 "$log3" | grep -qx "answered"$'"'"'\t'"'"'"q2"'

# A correction to an answer already sent is recorded as amended, so the log
# says what the worker was finally told (measured in a real run: a misread "1").
env -u MCV_TASK "$S" --task shop/t3 amended q1 "b: run the cases on Dev, within the scope given"; rc=$?
expect "amending an answered question succeeds" '[[ $rc -eq 0 ]]' "rc=$rc"
expect "amended line recorded with its text" \
  '[[ "$(tail -1 "$log3" | cut -f2-4)" == "amended"$'"'"'\t'"'"'"q1"$'"'"'\t'"'"'"b: run the cases on Dev, within the scope given" ]]' "$(tail -1 "$log3")"
env -u MCV_TASK "$S" --task shop/t3 amended q1 "a second correction" >/dev/null 2>&1; rc=$?
expect "an answer can be amended again" '[[ $rc -eq 0 ]]' "rc=$rc"
out="$(env -u MCV_TASK "$S" --task shop/t3 amended q2 "not answered yet" 2>&1)"; rc=$?
expect "amending an unanswered question exits 1, pointing to answered" \
  '[[ $rc -eq 1 && "$out" == *"not answered"*"answered"* ]]' "rc=$rc $out"
MCV_TASK=shop/t3 "$S" --task shop/t3 amended q1 "self" >/dev/null 2>&1; rc=$?
expect "a worker cannot amend" '[[ $rc -eq 1 ]]' "rc=$rc"

# An order that answers no question, given while the worker is busy, is kept
# as pending under an order id the script picks (measured in a real run: "push
# item 1" was refused four times and held only in the coordinator's memory).
out="$(env -u MCV_TASK "$S" --task shop/t3 pending - "push item 1")"; rc=$?
expect "pending - queues an order and prints its id o1" '[[ $rc -eq 0 && "$out" == o1 ]]' "rc=$rc $out"
expect "the order is a pending line under o1" \
  '[[ "$(tail -1 "$log3" | cut -f2-4)" == "pending"$'"'"'\t'"'"'"o1"$'"'"'\t'"'"'"push item 1" ]]' "$(tail -1 "$log3")"
out="$(env -u MCV_TASK "$S" --task shop/t3 pending - "then open the MR")"
expect "a second order gets o2" '[[ "$out" == o2 ]]' "$out"
env -u MCV_TASK "$S" --task shop/t3 pending o1 "push item 1" >/dev/null; rc=$?
expect "an order refused as busy can be queued again under its id" '[[ $rc -eq 0 ]]' "rc=$rc"
out="$(env -u MCV_TASK "$S" --task shop/t3 pending - "third")"
expect "queuing again does not reuse an id" '[[ "$out" == o3 ]]' "$out"
env -u MCV_TASK "$S" --task shop/t3 answered o1 "push item 1"; rc=$?
expect "a sent order is recorded with answered" '[[ $rc -eq 0 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t3 answered o1 "again" >/dev/null 2>&1; rc=$?
expect "an order is recorded as sent once" '[[ $rc -eq 1 ]]' "rc=$rc"
out="$(env -u MCV_TASK "$S" --task shop/t3 answered o9 "never queued" 2>&1)"; rc=$?
expect "an order that was never queued exits 1, naming it" '[[ $rc -eq 1 && "$out" == *"no order o9"* ]]' "rc=$rc $out"
env -u MCV_TASK "$S" --task shop/t3 pending o9 "x" >/dev/null 2>&1; rc=$?
expect "pending under an order id never given exits 1" '[[ $rc -eq 1 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t3 answered - "x" >/dev/null 2>&1; rc=$?
expect "- is only for pending" '[[ $rc -eq 2 || $rc -eq 1 ]]' "rc=$rc"
MCV_TASK=shop/t3 "$S" --task shop/t3 pending - "self" >/dev/null 2>&1; rc=$?
expect "a worker cannot queue an order" '[[ $rc -eq 1 ]]' "rc=$rc"
env -u MCV_TASK "$S" --task shop/t3 pending - "   " >/dev/null 2>&1; rc=$?
expect "an empty order is refused" '[[ $rc -eq 2 ]]' "rc=$rc"
# A worker that has not written a line yet has no status.log.
mkdir -p "$home/shop/tasks/t4"
echo '{}' >"$home/shop/tasks/t4/meta"
out="$(env -u MCV_TASK "$S" --task shop/t4 pending - "start with the cart" 2>&1)"; rc=$?
expect "an order for a worker with no log yet is o1" '[[ $rc -eq 0 && "$out" == o1 ]]' "rc=$rc $out"

# A question comes in parts, so the coordinator places them instead of
# cutting a paragraph down (measured over 49 real questions: 16 lines at the
# median, the question itself somewhere inside the background). The parts
# go into the one text field, each after a pilcrow, lettered by the script.
mkdir -p "$home/shop/tasks/t5"
echo '{}' >"$home/shop/tasks/t5/meta"
log5="$home/shop/tasks/t5/status.log"
text5() { tail -1 "$log5" | cut -f4; }
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Commit item 1 now, or keep it staged?" \
  --why "Item 2 needs another branch, and a stash is shared between worktrees." \
  --option "commit item 1 now" "item 2 starts on its own branch" \
  --option "keep it staged" "I stop here" \
  --recommend a 2>&1)"; rc=$?
expect "a question in parts is accepted and numbered" '[[ $rc -eq 0 && "$out" == q1 ]]' "rc=$rc $out"
want="Commit item 1 now, or keep it staged? ¶ why: Item 2 needs another branch, and a stash is shared between worktrees. ¶ a: commit item 1 now => item 2 starts on its own branch ¶ b: keep it staged => I stop here ¶ recommends: a"
got="$(text5)"
expect "its parts are stored in order, lettered" '[[ "$got" == "$want" ]]' "$got"
expect "a question in parts is still one line of four fields" \
  '[[ $(wc -l <"$log5") -eq 1 && $(awk -F"\t" "{print NF}" "$log5") -eq 4 ]]' "$(cat "$log5")"

out="$(MCV_TASK=shop/t5 "$S" needs-decision "Which port does the staging API use?" 2>&1)"; rc=$?
got="$(text5)"
expect "a question with nothing to choose from needs no options" \
  '[[ $rc -eq 0 && "$out" == q2 && "$got" == "Which port does the staging API use?" ]]' "rc=$rc $out / $got"
out="$(MCV_TASK=shop/t5 "$S" needs-decision Keep the old route --why it is still linked 2>&1)"; rc=$?
got="$(text5)"
expect "words given without quotes are kept, in the question and in a part" \
  '[[ $rc -eq 0 && "$got" == "Keep the old route ¶ why: it is still linked" ]]' "rc=$rc $got"

before="$(wc -l <"$log5")"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --option "yes" "it goes out today" 2>&1)"; rc=$?
expect "a single option is refused: it is not a choice" '[[ $rc -eq 2 && "$out" == *"at least two"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --option "yes" --option "no" 2>&1)"; rc=$?
expect "an option without what follows from it is refused" '[[ $rc -eq 2 && "$out" == *"what follows"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --option "yes" "out today" --option "no" "next week" --recommend c 2>&1)"; rc=$?
expect "recommending a letter no option has is refused" '[[ $rc -eq 2 && "$out" == *"--recommend"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --recommend a 2>&1)"; rc=$?
expect "recommending without options is refused" '[[ $rc -eq 2 && "$out" == *"--recommend"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision --why "no question here" 2>&1)"; rc=$?
expect "parts without a question are refused" '[[ $rc -eq 2 ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --why "   " 2>&1)"; rc=$?
expect "an empty part is refused" '[[ $rc -eq 2 && "$out" == *"--why"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" note "halfway" --why "x" 2>&1)"; rc=$?
expect "a kind that has no parts keeps such words as text" \
  '[[ $rc -eq 0 && "$(text5)" == "halfway --why x" ]]' "rc=$rc $(text5)"
expect "a refused question writes nothing" '[[ $(wc -l <"$log5") -eq $((before + 1)) ]]' "$(cat "$log5")"

# The mark between parts cannot come from the worker's own words, or a part
# could be made to look like two.
MCV_TASK=shop/t5 "$S" needs-decision "Use ¶ here?" --option "yes ¶ b: fake" "fine" --option "no" "also fine" >/dev/null 2>&1
got="$(text5)"
expect "a pilcrow in the worker's words is taken out" \
  '[[ "$got" == "Use   here? ¶ a: yes   b: fake => fine ¶ b: no => also fine" ]]' "$got"
MCV_TASK=shop/t5 "$S" needs-decision "รวมค่าธรรมเนียมต่อแก้ว หรือต่อออเดอร์?" --option "ต่อแก้ว" "ตรงกับใบเสร็จ" --option "ต่อออเดอร์" "ง่ายกว่า" --recommend a >/dev/null 2>&1
got="$(text5)"
expect "Thai parts come through whole" \
  '[[ "$got" == "รวมค่าธรรมเนียมต่อแก้ว หรือต่อออเดอร์? ¶ a: ต่อแก้ว => ตรงกับใบเสร็จ ¶ b: ต่อออเดอร์ => ง่ายกว่า ¶ recommends: a" ]]' "$got"

# A finished task says what was checked and what is left the same way (150
# real DONE messages: 13 lines at the median, 38 at the longest).
out="$(MCV_TASK=shop/t5 "$S" "done" "Opened merge request web!12 into develop" \
  --checked "tests pass; before and after pages captured" --left "the capture files, until you have seen the pages" 2>&1)"; rc=$?
got="$(text5)"
expect "done takes what was checked and what is left" \
  '[[ $rc -eq 0 && -z "$out" && "$got" == "Opened merge request web!12 into develop ¶ checked: tests pass; before and after pages captured ¶ left: the capture files, until you have seen the pages" ]]' "rc=$rc $out / $got"
# What waits for the user goes apart from what is merely left, lettered, so
# a decision is not buried in a list of loose ends (a real DONE on pps-web
# had "lot 55 will hit the size ceiling" among four other "left" items).
out="$(MCV_TASK=shop/t5 "$S" "done" "Opened merge request web!12" --needs "look at the before and after page" \
  --needs "open an issue for the old Add Employee bug?" --checked "tests pass" --left "pipeline still running" 2>&1)"; rc=$?
got="$(text5)"
expect "done letters each --needs, after the result and before what was checked" \
  '[[ $rc -eq 0 && -z "$out" && "$got" == "Opened merge request web!12 ¶ needs a: look at the before and after page ¶ needs b: open an issue for the old Add Employee bug? ¶ checked: tests pass ¶ left: pipeline still running" ]]' "rc=$rc $out / $got"
out="$(MCV_TASK=shop/t5 "$S" "done" "x" --needs 1 --needs 2 --needs 3 --needs 4 --needs 5 --needs 6 --needs 7 2>&1)"; rc=$?
expect "at most six --needs" '[[ $rc -eq 2 && "$out" == *"--needs"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" "done" "x" --needs "  " 2>&1)"; rc=$?
expect "an empty --needs is refused" '[[ $rc -eq 2 && "$out" == *"--needs"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --needs "x" 2>&1)"; rc=$?
expect "a question refuses --needs, which belongs to done" '[[ $rc -eq 2 && "$out" == *"--needs"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" "done" "Cart total fixed" --option "a" "b" 2>&1)"; rc=$?
expect "done refuses a part that belongs to a question" '[[ $rc -eq 2 && "$out" == *"--option"* ]]' "rc=$rc $out"
out="$(MCV_TASK=shop/t5 "$S" needs-decision "Ship it?" --checked "tests" 2>&1)"; rc=$?
expect "a question refuses a part that belongs to done" '[[ $rc -eq 2 && "$out" == *"--checked"* ]]' "rc=$rc $out"

c5="$(MCV_TASK=shop/t5 "$S" --contract)"
ctx5="$(jq -r .hookSpecificOutput.additionalContext <<<"$c5")"
expect "the contract shows a question's parts" \
  '[[ "$ctx5" == *"--why"*"--option"*"--recommend"* ]]'
expect "the contract shows done's parts" '[[ "$ctx5" == *"--needs"*"--checked"*"--left"* ]]'
expect "the contract keeps what waits for the user out of --left" \
  '[[ "$ctx5" == *"--needs for each thing the user must decide or do"* ]]'
expect "the contract asks for the question alone on its line" \
  '[[ "$ctx5" == *"The question is one short sentence"* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
