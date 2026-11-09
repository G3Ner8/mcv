#!/usr/bin/env bash
#
# Tests for bin/mcv-watch, one poll at a time (--once) against a stub herdr.
# Needs bash and jq; no herdr.
# Run: tests/test-watch.sh   (exit 0 when every check passes)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
W="$(cd "$HERE/../bin" && pwd -P)/mcv-watch"
STATUS="$(dirname "$W")/mcv-status"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export MCV_HOME="$root/home" MCV_HERDR="$HERE/fixtures/stub-herdr.sh" STUB_AGENTS="$root/agents"
export MCV_WATCH_STATE="$root/state"
mkdir -p "$MCV_WATCH_STATE"
# The checks below read the raw, tab-separated form; the readable form the
# coordinator sees is checked at the end.
export MCV_WATCH_RAW=1

# A task as spawn leaves it: a meta file naming its pane.
task() { # <id> <pane>
  mkdir -p "$MCV_HOME/acme/tasks/$1"
  printf '{"task":"acme/%s","pane_id":"%s"}\n' "$1" "$2" >"$MCV_HOME/acme/tasks/$1/meta"
}
agents() { printf '%s' "$*" | tr '|' '\n' | tr ',' '\t' >"$STUB_AGENTS"; }  # "p1,working,3,acme-a|..."
say() { MCV_TASK="acme/$1" "$STATUS" "$2" "$3" >/dev/null; }                  # <id> <kind> <text>
poll() { "$W" acme --once; }
count() { if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

# Without a state folder, --once refuses.
out="$(env -u MCV_WATCH_STATE "$W" acme --once 2>&1)"; rc=$?
expect "--once without MCV_WATCH_STATE exits 2" '[[ $rc -eq 2 ]]' "rc=$rc $out"

# First poll: report only tasks already blocked or done; never replay old lines.
task a w:p1; task b w:p2; task c w:p3
say a note "old line before the watcher started"
agents "w:p1,working,1,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "first poll: two events" '[[ $(count "$out") -eq 2 ]]' "$out"
expect "first poll reports b done" '[[ "$out" == *"acme/b"$'"'"'\t'"'"'"state"$'"'"'\t'"'"'"done"* ]]' "$out"
expect "first poll reports c blocked" '[[ "$out" == *"acme/c"$'"'"'\t'"'"'"state"$'"'"'\t'"'"'"blocked"* ]]' "$out"
expect "first poll does not replay old log lines" '[[ "$out" != *"old line"* ]]' "$out"

# Nothing changed: nothing printed.
out="$(poll)"
expect "no change: no events" '[[ -z "$out" ]]' "$out"

# needs-decision, then the turn ends: one event, the question.
say a needs-decision "Session or query string?"
agents "w:p1,done,2,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "question then turn end: one event" '[[ $(count "$out") -eq 1 ]]' "$out"
expect "that event is the question, with its id" \
  '[[ "$out" == *"acme/a"$'"'"'\t'"'"'"needs-decision"$'"'"'\t'"'"'"q1"$'"'"'\t'"'"'"Session or query string?" ]]' "$out"

# The question arrives in one poll and the turn end in the next: still suppressed.
agents "w:p1,working,3,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "working is never printed" '[[ -z "$out" ]]' "$out"
say a needs-decision "Keep the old route?"
out="$(poll)"
expect "question in its own poll: one event" '[[ $(count "$out") -eq 1 ]]' "$out"
agents "w:p1,done,4,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "turn end after a question in an earlier poll: no event" '[[ -z "$out" ]]' "$out"

# note, then the turn ends: two events.
agents "w:p1,working,5,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
poll >/dev/null
say a note "halfway"
agents "w:p1,done,6,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "note then turn end: two events" '[[ $(count "$out") -eq 2 ]]' "$out"
expect "note comes first, then state done" \
  '[[ "$(printf "%s\n" "$out" | cut -f3 | tr "\n" " ")" == "note state " ]]' "$out"

# A turn that ends with no log line at all: one state done (the safety net).
agents "w:p1,working,7,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
poll >/dev/null
agents "w:p1,done,8,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "silent turn end: one state done" \
  '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"done" ]]' "$out"

# A whole turn between two polls (done -> working -> done) is still seen.
agents "w:p1,done,10,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "turn missed between polls: state done from the counter" \
  '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"done" ]]' "$out"

# done -> idle (output viewed) is not printed.
agents "w:p1,idle,11,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "idle is never printed" '[[ -z "$out" ]]' "$out"

# A worker reaching a dialog: state blocked.
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "blocked is printed" '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"blocked" ]]' "$out"

# The coordinator's own answer lines are never printed.
env -u MCV_TASK "$STATUS" --task acme/a answered q1 "session" >/dev/null
out="$(poll)"
expect "answered lines are not printed" '[[ -z "$out" ]]' "$out"

# A pane that disappears: gone, once.
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b"
out="$(poll)"
expect "vanished pane: gone" '[[ $(count "$out") -eq 1 && "$out" == *"acme/c"$'"'"'\t'"'"'"gone"* ]]' "$out"
out="$(poll)"
expect "gone is printed once" '[[ -z "$out" ]]' "$out"

# A task spawned after the watcher started: its log is followed from the start.
task d w:p4
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b|w:p4,idle,1,acme-d"
say d note "first words"
out="$(poll)"
expect "new task: its first log line is printed" '[[ "$out" == *"acme/d"$'"'"'\t'"'"'"note"$'"'"'\t'"'"'"-"$'"'"'\t'"'"'"first words" ]]' "$out"

# Every line: five tab-separated fields for log events, four for state events.
say d failed "giving up"
out="$(poll)"
expect "log event has five fields" '[[ $(awk -F"\t" "{print NF}" <<<"$out") -eq 5 ]]' "$out"
expect "event starts with a UTC timestamp" '[[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]' "$out"

# A worker spawn is still starting (marker set, not yet an agent) is not gone.
task e w:p5
: >"$MCV_HOME/acme/tasks/e/starting"
out="$(poll)"
expect "starting worker missing from the agent list: no gone" '[[ "$out" != *"acme/e"* ]]' "$out"
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b|w:p4,idle,1,acme-d|w:p5,idle,1,acme-e"
out="$(poll)"
expect "started worker seen idle: nothing printed" '[[ "$out" != *"acme/e"* ]]' "$out"
# Once seen, a worker that disappears is gone even if the marker remains.
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b|w:p4,idle,1,acme-d"
out="$(poll)"
expect "seen worker that vanishes is gone despite the marker" '[[ "$out" == *"acme/e"$'"'"'\t'"'"'"gone"* ]]' "$out"

# A task removed and spawned again under the same id within one poll: the new
# worker's first question is printed though its log is shorter than the old.
base_agents="w:p1,blocked,12,acme-a|w:p2,done,4,acme-b|w:p4,idle,1,acme-d"
task f w:p6
agents "$base_agents|w:p6,working,1,acme-f"
say f note one; say f note two; say f note three
poll >/dev/null
rm -rf "$MCV_HOME/acme/tasks/f"
task f w:p7
agents "$base_agents|w:p7,working,1,acme-f"
say f needs-decision "which db?"
out="$(poll)"
expect "respawned id: the new worker's question is printed" '[[ "$out" == *"needs-decision"$'"'"'\t'"'"'"q1"$'"'"'\t'"'"'"which db?" ]]' "$out"

# A log that was started again (shorter than what was read) is followed from
# its start. mcv only appends, so this is a log cut by hand.
say f note x; say f note y
poll >/dev/null
printf '' >"$MCV_HOME/acme/tasks/f/status.log"
say f note "after truncation"
out="$(poll)"
expect "truncated log: its new line is printed" '[[ "$out" == *"after truncation" ]]' "$out"

# A damaged state line or a damaged meta does not stop the watcher.
: >"$MCV_WATCH_STATE/acme/f"
say d note "still here"
out="$(poll 2>"$root/err")"; rc=$?
expect "damaged state: the poll still succeeds" '[[ $rc -eq 0 ]]' "rc=$rc"
expect "damaged state: other tasks still report" '[[ "$out" == *"still here" ]]' "$out"
expect "damaged state: a warning on stderr" 'grep -q "acme/f: state was damaged" "$root/err"' "$(cat "$root/err")"
mkdir -p "$MCV_HOME/acme/tasks/g"
echo 'not json' >"$MCV_HOME/acme/tasks/g/meta"
say d note "and here"
out="$(poll 2>&1)"; rc=$?
expect "damaged meta: the poll still succeeds and reports others" '[[ $rc -eq 0 && "$out" == *"and here" ]]' "rc=$rc $out"
rm -rf "$MCV_HOME/acme/tasks/g"

# herdr failing: log lines are still passed on; the warning comes once.
say d note "herdr is down"
out="$(STUB_DOWN=1 poll 2>"$root/err")"; rc=$?
expect "herdr down: log lines still printed" '[[ $rc -eq 0 && "$out" == *"herdr is down" ]]' "rc=$rc $out"
expect "herdr down: one warning" 'grep -q "worker states unavailable" "$root/err"' "$(cat "$root/err")"
out="$(STUB_DOWN=1 poll 2>"$root/err")"
expect "herdr still down: no second warning" '[[ ! -s "$root/err" ]]' "$(cat "$root/err")"
out="$(poll 2>&1)"
expect "herdr back: no gone for workers it lists" '[[ "$out" != *gone* ]]' "$out"

# Two projects sharing one state folder do not reset each other.
mkdir -p "$MCV_HOME/other/tasks"
"$W" other --once >/dev/null
out="$(poll)"
expect "another project's poll in the same state folder: nothing replayed" '[[ -z "$out" ]]' "$out"

# A watcher started after questions were asked shows the ones still open,
# once, and nothing else from the past.
export MCV_WATCH_STATE="$root/state2"
mkdir -p "$MCV_WATCH_STATE"
task h w:p8
agents "w:p8,done,5,acme-h"
say h needs-decision "first?"
env -u MCV_TASK "$STATUS" --task acme/h answered q1 "yes" >/dev/null
say h note "progress"
say h needs-decision "second?"
out="$(poll 2>/dev/null)"
expect "new watcher: the open question is shown" '[[ "$out" == *"acme/h"$'"'"'\t'"'"'"needs-decision"$'"'"'\t'"'"'"q2"$'"'"'\t'"'"'"second?" ]]' "$out"
expect "new watcher: the answered question and the note are not" '[[ "$out" != *"first?"* && "$out" != *progress* ]]' "$out"
expect "new watcher: no state done on top of the open question" '[[ "$out" != *"acme/h"$'"'"'\t'"'"'"state"* ]]' "$out"
out="$(poll 2>/dev/null)"
expect "the open question is shown once" '[[ "$out" != *"second?"* ]]' "$out"

# Damaged state shows the open questions again rather than losing them.
: >"$MCV_WATCH_STATE/acme/h"
out="$(poll 2>/dev/null)"
expect "damaged state: the open question is shown again" '[[ "$out" == *"second?" ]]' "$out"

# A blank line in a log is not an event and does not lose what follows.
printf '\n' >>"$MCV_HOME/acme/tasks/h/status.log"
out="$(poll 2>/dev/null)"
expect "a blank log line prints nothing" '[[ "$out" != *"acme/h"* ]]' "$out"
say h needs-decision "third?"
out="$(poll 2>&1)"
expect "the question after a blank line is shown, with no state warning" \
  '[[ "$out" == *"third?" && "$out" != *damaged* ]]' "$out"

# A log that cannot be read skips that task; the others are still reported.
if [[ "$(id -u)" -ne 0 ]]; then
  task i w:p9
  agents "w:p8,done,5,acme-h|w:p9,idle,1,acme-i"
  poll >/dev/null 2>&1
  say i note "unreadable soon"
  chmod 000 "$MCV_HOME/acme/tasks/i/status.log"
  say h note "still flowing"
  out="$(poll 2>&1)"; rc=$?
  chmod 600 "$MCV_HOME/acme/tasks/i/status.log"
  expect "an unreadable log does not stop the watcher" '[[ $rc -eq 0 && "$out" == *"still flowing" ]]' "rc=$rc $out"
  out="$(poll 2>&1)"
  expect "once readable again, its line is shown" '[[ "$out" == *"unreadable soon" ]]' "$out"
else
  ok "an unreadable log (skipped: running as root)"
  ok "once readable again (skipped: running as root)"
fi

# An answer the coordinator could not send because the worker was still busy
# after asking is kept as pending; the watcher hands it back, as one deliver
# event, when the worker stops. Without it the turn end was suppressed (the
# last log line is the question) and both sides waited for ever.
# Project "brew", so the acme tasks above stay out of it.
export MCV_WATCH_STATE="$root/state3"
mkdir -p "$MCV_WATCH_STATE"
btask() { mkdir -p "$MCV_HOME/brew/tasks/$1"; printf '{"task":"brew/%s","pane_id":"%s"}\n' "$1" "$2" >"$MCV_HOME/brew/tasks/$1/meta"; }
bsay() { MCV_TASK="brew/$1" "$STATUS" "$2" "$3" >/dev/null; }
bpend() { env -u MCV_TASK "$STATUS" --task "brew/$1" pending "$2" "$3" >/dev/null; }
bans() { env -u MCV_TASK "$STATUS" --task "brew/$1" answered "$2" "$3" >/dev/null; }
bpoll() { "$W" brew --once; }
TAB=$'\t'

btask j b:p1
agents "b:p1,working,1,brew-j"
bpoll >/dev/null
bsay j needs-decision "Per drink or per order?"
out="$(bpoll)"
expect "pending: the question is shown while the worker still works" '[[ "$out" == *"needs-decision${TAB}q1${TAB}"* ]]' "$out"
bpend j q1 "per drink"
out="$(bpoll)"
expect "pending recorded while the worker works: no event yet" '[[ -z "$out" ]]' "$out"
agents "b:p1,done,2,brew-j"
out="$(bpoll)"
expect "worker stops with a pending answer: one event" '[[ $(count "$out") -eq 1 ]]' "$out"
expect "that event is deliver, with the question id and the answer" \
  '[[ "$out" == *"brew/j${TAB}deliver${TAB}q1${TAB}per drink" ]]' "$out"
out="$(bpoll)"
expect "deliver is not repeated while nothing changes" '[[ -z "$out" ]]' "$out"
agents "b:p1,idle,3,brew-j"
out="$(bpoll)"
expect "done -> idle does not repeat deliver" '[[ -z "$out" ]]' "$out"
# The coordinator sends the delivered answer; the worker's next turn can end
# before the answer is recorded. That stop must not deliver it again.
agents "b:p1,working,31,brew-j"; bpoll >/dev/null
agents "b:p1,done,32,brew-j"
out="$(bpoll)"
expect "a stop after the deliver, before answered is recorded, does not deliver again" '[[ "$out" != *deliver* ]]' "$out"
# A send that failed is recorded as pending again, and delivered again.
bpend j q1 "per drink, rounded"
out="$(bpoll)"
expect "a new pending line for the same question is delivered" \
  '[[ "$out" == *"brew/j${TAB}deliver${TAB}q1${TAB}per drink, rounded" && $(count "$out") -eq 1 ]]' "$out"
bans j q1 "per drink"
agents "b:p1,working,4,brew-j"; bpoll >/dev/null
agents "b:p1,done,5,brew-j"
out="$(bpoll)"
expect "once answered, a later stop has no deliver" '[[ "$out" != *deliver* ]]' "$out"

# The worker had already stopped when the pending answer was recorded.
btask k b:p2
agents "b:p1,done,5,brew-j|b:p2,working,1,brew-k"
bpoll >/dev/null
bsay k needs-decision "Round up?"
agents "b:p1,done,5,brew-j|b:p2,done,2,brew-k"
bpoll >/dev/null
bpend k q1 "no"
out="$(bpoll)"
expect "pending recorded after the worker stopped: deliver at once" '[[ "$out" == *"brew/k${TAB}deliver${TAB}q1${TAB}no" ]]' "$out"
bans k q1 "no"

# herdr down when the pending answer is read: deliver once herdr is back.
btask l b:p3
agents "b:p1,done,5,brew-j|b:p2,done,2,brew-k|b:p3,working,1,brew-l"
bpoll >/dev/null
bsay l needs-decision "Which cup size?"
agents "b:p1,done,5,brew-j|b:p2,done,2,brew-k|b:p3,idle,2,brew-l"
bpoll >/dev/null
bpend l q1 "medium"
out="$(STUB_DOWN=1 bpoll 2>/dev/null)"
expect "herdr down: no deliver yet" '[[ "$out" != *deliver* ]]' "$out"
out="$(bpoll)"
expect "herdr back: the pending answer is delivered" '[[ "$out" == *"brew/l${TAB}deliver${TAB}q1${TAB}medium" ]]' "$out"

# A watcher started later shows a pending answer as deliver, not the question
# again, so the user is not asked twice.
export MCV_WATCH_STATE="$root/state4"
mkdir -p "$MCV_WATCH_STATE"
out="$(bpoll 2>/dev/null)"
expect "new watcher: a stopped worker's pending answer is delivered" '[[ "$out" == *"brew/l${TAB}deliver${TAB}q1${TAB}medium" ]]' "$out"
expect "new watcher: its question is not shown again" '[[ "$out" != *"Which cup size?"* ]]' "$out"

# A project with no tasks folder (a misspelt name, or nothing spawned yet)
# is said once on stderr, so a silent watcher is not mistaken for a quiet one.
out="$(MCV_WATCH_STATE="$root/state5" "$W" nosuch --once 2>&1 >/dev/null)"; rc=$?
expect "a project with no tasks is named on stderr" '[[ $rc -eq 0 && "$out" == *"no tasks"*"nosuch"* ]]' "rc=$rc $out"
out="$(MCV_WATCH_STATE="$root/state5" "$W" nosuch --once 2>&1 >/dev/null)"
expect "and only once" '[[ -z "$out" ]]' "$out"

# The long-running watcher stops at once on TERM, not after its interval.
MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >/dev/null 2>&1 &
wpid=$!
sleep 1
start=$(date +%s)
kill -TERM "$wpid"
wait "$wpid" 2>/dev/null
took=$(( $(date +%s) - start ))
expect "TERM stops the watcher within 2 seconds (interval 30)" '[[ $took -le 2 ]]' "took ${took}s"

# One watcher per project: a second one refuses, naming the first's pid, so
# no event is printed twice. A watcher that died without cleaning up does not
# block the next.
MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >/dev/null 2>&1 &
wpid=$!
sleep 1
# Run in the background and stopped after a second, so a watcher that does
# not refuse fails this check instead of hanging the suite.
MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >"$root/w2.out" 2>&1 &
w2=$!
sleep 1
if kill -0 "$w2" 2>/dev/null; then
  kill -TERM "$w2"; wait "$w2" 2>/dev/null; rc=running
else
  wait "$w2"; rc=$?
fi
out="$(cat "$root/w2.out")"
expect "a second watcher for the same project refuses at once" \
  '[[ $rc == 1 && "$out" == *"already running"*"$wpid"* ]]' "rc=$rc $out"
MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" brew >/dev/null 2>&1 &
bpid=$!
sleep 1
expect "a watcher for another project runs alongside" 'kill -0 "$bpid" 2>/dev/null'
kill -TERM "$wpid" "$bpid"; wait "$wpid" "$bpid" 2>/dev/null
sleep 0 & dead=$!; wait "$dead"
mkdir -p "$MCV_HOME/acme/watch.lock"; echo "$dead" >"$MCV_HOME/acme/watch.lock/pid"
MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >/dev/null 2>&1 &
wpid=$!
sleep 1
expect "a lock left by a dead watcher is taken over" 'kill -0 "$wpid" 2>/dev/null'
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
expect "a stopped watcher releases its lock" '[[ ! -e "$MCV_HOME/acme/watch.lock" ]]'

# Several watchers that find the same stale lock at the same moment: exactly
# one takes it over and the rest refuse. Each round starts four at once; the
# race is a matter of timing, so a few rounds make a miss unlikely.
race_ok=1
race_why=""
for round in 1 2 3 4 5; do
  mkdir -p "$MCV_HOME/acme/watch.lock"; echo "$dead" >"$MCV_HOME/acme/watch.lock/pid"
  pids=()
  for n in 1 2 3 4; do
    MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >"$root/race$n.out" 2>&1 &
    pids+=("$!")
  done
  sleep 3
  alive=0
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
  refused=0
  for n in 1 2 3 4; do grep -q "already running" "$root/race$n.out" && refused=$((refused + 1)); done
  kill -TERM "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
  if [[ $alive -ne 1 || $refused -ne 3 ]]; then
    race_ok=0; race_why="round $round: $alive running, $refused refused: $(cat "$root"/race*.out)"; break
  fi
done
expect "of four watchers racing for a stale lock, one runs and three refuse" '[[ $race_ok -eq 1 ]]' "$race_why"
expect "the racing watchers leave no lock behind" '[[ ! -e "$MCV_HOME/acme/watch.lock" ]]' \
  "$(ls -la "$MCV_HOME/acme" 2>&1)"

# A takeover lock left by a watcher killed mid-takeover does not block the
# next one for good.
mkdir -p "$MCV_HOME/acme/watch.lock" "$MCV_HOME/acme/watch.lock.takeover"
echo "$dead" >"$MCV_HOME/acme/watch.lock/pid"
MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >/dev/null 2>&1 &
wpid=$!
sleep 7
expect "a leftover takeover lock is cleared and the stale lock taken over" \
  'kill -0 "$wpid" 2>/dev/null && [[ "$(cat "$MCV_HOME/acme/watch.lock/pid")" == "$wpid" ]]'
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null

# A dialog answered in the worker's pane: blocked, then working again. The
# coordinator hears that it moved on, so it stops asking for an approval no
# longer on screen. Working after any other state stays quiet.
rm -rf "$MCV_HOME/acme/tasks" "$MCV_WATCH_STATE"/acme
task r w:p9
agents "w:p9,working,1,acme-r"
poll >/dev/null
agents "w:p9,blocked,2,acme-r"
out="$(poll)"
expect "blocked is reported" '[[ "$out" == *"acme/r"$'"'"'\t'"'"'"state"$'"'"'\t'"'"'"blocked" ]]' "$out"
agents "w:p9,working,3,acme-r"
out="$(poll)"
expect "blocked then working: reported as state working" \
  '[[ $(count "$out") -eq 1 && "$out" == *"acme/r"$'"'"'\t'"'"'"state"$'"'"'\t'"'"'"working" ]]' "$out"
agents "w:p9,done,4,acme-r"
poll >/dev/null
agents "w:p9,working,5,acme-r"
out="$(poll)"
expect "done then working: nothing" '[[ -z "$out" ]]' "$out"

# The readable form, as the coordinator sees it.
unset MCV_WATCH_RAW
rm -rf "$MCV_HOME/acme/tasks" "$MCV_WATCH_STATE"/acme
task v w:p8
agents "w:p8,working,1,acme-v"
poll >/dev/null
say v needs-decision "Session or query string?"
say v note "halfway"
say v "done" "admin!221 opened, not merged"
out="$(poll)"
expect "readable: a question carries its id" \
  '[[ "$(sed -n 1p <<<"$out")" == "⧉ v · QUESTION q1 · Session or query string?" ]]' "$out"
expect "readable: a note" '[[ "$(sed -n 2p <<<"$out")" == "⧉ v · NOTE · halfway" ]]' "$out"
expect "readable: done" '[[ "$(sed -n 3p <<<"$out")" == "⧉ v · DONE · admin!221 opened, not merged" ]]' "$out"
agents "w:p8,blocked,2,acme-v"
out="$(poll)"
expect "readable: a dialog is WAITING" '[[ "$out" == "⧉ v · WAITING · a dialog is open in its pane" ]]' "$out"
agents "w:p8,working,3,acme-v"
out="$(poll)"
expect "readable: leaving it is RESUMED" '[[ "$out" == "⧉ v · RESUMED · "* ]]' "$out"
agents "w:p8,done,4,acme-v"
out="$(poll)"
expect "readable: a turn end with no report is STOPPED, telling to read the screen" \
  '[[ "$out" == "⧉ v · STOPPED · "*"read its screen" ]]' "$out"
"$STATUS" --task acme/v pending q1 "query string" >/dev/null
agents "w:p8,working,5,acme-v"
poll >/dev/null
agents "w:p8,done,6,acme-v"
out="$(poll)"
expect "readable: a pending answer is DELIVER with its id" '[[ "$out" == "⧉ v · DELIVER q1 · query string" ]]' "$out"
agents ""
out="$(poll)"
expect "readable: GONE" '[[ "$out" == "⧉ v · GONE · "* ]]' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
