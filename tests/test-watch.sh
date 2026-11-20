#!/usr/bin/env bash
#
# Tests for bin/mcv-watch, one poll at a time (--once) against a stub herdr.
# Needs bash, jq and perl (to time when lines arrive); no herdr.
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
# Work from the temporary folder: a git command given an empty path runs in
# the current folder, which must never be the checkout this was started from.
cd "$root" || exit 1
export MCV_HOME="$root/home" MCV_HERDR="$HERE/fixtures/stub-herdr.sh" STUB_AGENTS="$root/agents"
export MCV_WATCH_STATE="$root/state"
# No Claude process to belong to, unless a check says so: run from a Claude
# session, every watcher here would otherwise find the same one.
export MCV_WATCH_OWNER=""
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
# A prompt sent to a worker, as mcv-herdr.sh journals it: <UTC time> <id>.
sent() { mkdir -p "$MCV_HOME/acme"; printf '%s\tprompt\tacme/%s\tok: sent 5 characters, state working\n' "$1" "$2" >>"$MCV_HOME/acme/journal.log"; }
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

# A note is for the status table, not a wake: alone it prints nothing, and a
# turn that ends after only a note is still a stop to look at, once the
# worker has been sent something after its questions (here, their answers).
sent 2999-01-01T00:00:00Z a
agents "w:p1,working,5,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
poll >/dev/null
say a note "halfway"
out="$(poll)"
expect "a note prints nothing" '[[ -z "$out" ]]' "$out"
agents "w:p1,done,6,acme-a|w:p2,done,4,acme-b|w:p3,blocked,2,acme-c"
out="$(poll)"
expect "note then turn end: one event, state done" \
  '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"done" ]]' "$out"

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
env -u MCV_TASK "$STATUS" --task acme/a amended q1 "query string" >/dev/null
out="$(poll)"
expect "amended lines are not printed" '[[ -z "$out" ]]' "$out"

# A pane that disappears: gone, once.
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b"
out="$(poll)"
expect "vanished pane: gone" '[[ $(count "$out") -eq 1 && "$out" == *"acme/c"$'"'"'\t'"'"'"gone"* ]]' "$out"
out="$(poll)"
expect "gone is printed once" '[[ -z "$out" ]]' "$out"

# A task spawned after the watcher started: its log is followed from the start.
task d w:p4
agents "w:p1,blocked,12,acme-a|w:p2,done,4,acme-b|w:p4,idle,1,acme-d"
say d blocked "first words"
out="$(poll)"
expect "new task: its first log line is printed" '[[ "$out" == *"acme/d"$'"'"'\t'"'"'"blocked"$'"'"'\t'"'"'"-"$'"'"'\t'"'"'"first words" ]]' "$out"

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
say f blocked "after truncation"
out="$(poll)"
expect "truncated log: its new line is printed" '[[ "$out" == *"after truncation" ]]' "$out"

# A damaged state line or a damaged meta does not stop the watcher.
: >"$MCV_WATCH_STATE/acme/f"
say d blocked "still here"
out="$(poll 2>"$root/err")"; rc=$?
expect "damaged state: the poll still succeeds" '[[ $rc -eq 0 ]]' "rc=$rc"
expect "damaged state: other tasks still report" '[[ "$out" == *"still here" ]]' "$out"
expect "damaged state: a warning on stderr" 'grep -q "acme/f: state was damaged" "$root/err"' "$(cat "$root/err")"
mkdir -p "$MCV_HOME/acme/tasks/g"
echo 'not json' >"$MCV_HOME/acme/tasks/g/meta"
say d blocked "and here"
out="$(poll 2>&1)"; rc=$?
expect "damaged meta: the poll still succeeds and reports others" '[[ $rc -eq 0 && "$out" == *"and here" ]]' "rc=$rc $out"
rm -rf "$MCV_HOME/acme/tasks/g"

# herdr failing: log lines are still passed on; the warning comes once.
say d blocked "herdr is down"
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
  say i blocked "unreadable soon"
  chmod 000 "$MCV_HOME/acme/tasks/i/status.log"
  say h blocked "still flowing"
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

# An order queued while the worker works (pending -) comes back the same way
# when it stops, each order once, in the order given.
btask m b:p4
agents "b:p1,done,5,brew-j|b:p2,done,2,brew-k|b:p3,idle,2,brew-l|b:p4,working,1,brew-m"
bpoll >/dev/null
bpend m - "push item 1"
bpend m - "then open the MR"
out="$(bpoll)"
expect "orders queued while the worker works: no event yet" '[[ -z "$out" ]]' "$out"
agents "b:p1,done,5,brew-j|b:p2,done,2,brew-k|b:p3,idle,2,brew-l|b:p4,done,2,brew-m"
out="$(bpoll)"
expect "worker stops: each order is delivered once, in order, with no STOPPED" \
  '[[ "$out" == *"brew/m${TAB}deliver${TAB}o1${TAB}push item 1"*"brew/m${TAB}deliver${TAB}o2${TAB}then open the MR" && $(count "$out") -eq 2 ]]' "$out"
bans m o1 "push item 1"; bans m o2 "then open the MR"
out="$(bpoll)"
expect "sent orders are not delivered again" '[[ -z "$out" ]]' "$out"
agents "b:p1,done,5,brew-j|b:p2,done,2,brew-k|b:p3,idle,2,brew-l"
rm -rf "$MCV_HOME/brew/tasks/m"

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

# /clear starts a new conversation in the same Claude process and leaves the
# old conversation's watcher running, lock and all, for up to 30 minutes
# (measured: three times in one day; once a task waited 22 minutes for it).
# A watcher started by the same Claude process replaces it; one from another
# process, or one that cannot tell, is refused as before.
MCV_WATCH_OWNER=4242 MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >/dev/null 2>&1 &
wpid=$!
sleep 1
second() { # <owner>: start a second watcher; sets w2, rc ("running" or its exit status) and out
  MCV_WATCH_OWNER="$1" MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >"$root/w2.out" 2>&1 &
  w2=$!
  sleep 2
  if kill -0 "$w2" 2>/dev/null; then rc=running; else wait "$w2"; rc=$?; fi
  out="$(cat "$root/w2.out")"
}
second 9999
expect "a watcher of another Claude process is refused" \
  '[[ $rc == 1 && "$out" == *"already running"*"$wpid"* ]] && kill -0 "$wpid" 2>/dev/null' "rc=$rc $out"
second ""
expect "a watcher that cannot tell its Claude process is refused" \
  '[[ $rc == 1 && "$out" == *"already running"* ]] && kill -0 "$wpid" 2>/dev/null' "rc=$rc $out"
second 4242
# Never wait on a watcher that is still running: it would hang the suite.
if kill -0 "$wpid" 2>/dev/null; then kill -KILL "$wpid"; wait "$wpid" 2>/dev/null; first_rc=alive; else wait "$wpid" 2>/dev/null; first_rc=$?; fi
expect "a watcher of the same Claude process replaces the earlier one" \
  '[[ $rc == running && $first_rc != alive ]] && [[ "$(cat "$MCV_HOME/acme/watch.lock/pid" 2>/dev/null)" == "$w2" ]]' \
  "rc=$rc first=$first_rc $out lock=$(cat "$MCV_HOME/acme/watch.lock/pid" 2>/dev/null) w2=$w2"
expect "the replaced watcher ended cleanly, so its Monitor reports no failure" '[[ $first_rc == 0 ]]' "rc=$first_rc"
expect "it says what it replaced" '[[ "$out" == *"replaced"*"$wpid"* ]]' "$out"
kill -TERM "$w2" 2>/dev/null; wait "$w2" 2>/dev/null
rm -rf "$MCV_HOME/acme/watch.lock"
# A holder from an older mcv wrote no owner: refused.
MCV_WATCH_OWNER=4242 MCV_WATCH_INTERVAL=30 env -u MCV_WATCH_STATE "$W" acme >/dev/null 2>&1 &
wpid=$!
sleep 1
rm -f "$MCV_HOME/acme/watch.lock/owner"
second 4242
expect "a holder with no owner recorded is refused" \
  '[[ $rc == 1 && "$out" == *"already running"* ]] && kill -0 "$wpid" 2>/dev/null' "rc=$rc $out"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null

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
# The watcher clears it after 5 seconds of its own waits, which take longer
# on a busy machine (measured: 9 seconds beside two working sessions).
i=0
while (( i < 60 )) && [[ "$(cat "$MCV_HOME/acme/watch.lock/pid" 2>/dev/null)" != "$wpid" ]]; do
  sleep 0.5
  i=$((i + 1))
done
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
# A worker that ends its turn to wait on background work says so with
# waiting. That stop is expected and wakes nobody, unless the worker is still
# stopped after MCV_WATCH_WAIT_LIMIT seconds: then it is a stuck wait, said
# once. MCV_WATCH_NOW stands in for the clock.
export MCV_WATCH_STATE="$root/state3"
mkdir -p "$MCV_WATCH_STATE"
rm -rf "$MCV_HOME/acme/tasks"
export MCV_WATCH_WAIT_LIMIT=600
task w w:p10
agents "w:p10,working,1,acme-w"
MCV_WATCH_NOW=1000 poll >/dev/null
say w waiting "qa pair, about 15 minutes"
out="$(MCV_WATCH_NOW=1000 poll)"
expect "waiting prints nothing" '[[ -z "$out" ]]' "$out"
agents "w:p10,done,2,acme-w"
out="$(MCV_WATCH_NOW=1010 poll)"
expect "turn end after waiting: no STOPPED" '[[ -z "$out" ]]' "$out"
agents "w:p10,idle,2,acme-w"
out="$(MCV_WATCH_NOW=1500 poll)"
expect "still waiting within the limit: nothing" '[[ -z "$out" ]]' "$out"
out="$(MCV_WATCH_NOW=1611 poll)"
expect "still stopped past the limit: one stuck-wait event" \
  '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"done"$'"'"'\t'"'"'"wait" ]]' "$out"
out="$(MCV_WATCH_NOW=2500 poll)"
expect "the stuck wait is said once" '[[ -z "$out" ]]' "$out"
# Woken by its background job, it works, then stops with no report: a stop.
agents "w:p10,working,3,acme-w"
MCV_WATCH_NOW=2600 poll >/dev/null
agents "w:p10,done,4,acme-w"
out="$(MCV_WATCH_NOW=2610 poll)"
expect "after the wait, a silent stop is STOPPED" \
  '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"done" ]]' "$out"
# A wait that ends early: woken within the limit, it waits again; nothing.
agents "w:p10,working,5,acme-w"
MCV_WATCH_NOW=2700 poll >/dev/null
say w waiting "build"
agents "w:p10,done,6,acme-w"
MCV_WATCH_NOW=2710 poll >/dev/null
agents "w:p10,working,7,acme-w"
MCV_WATCH_NOW=2800 poll >/dev/null
say w waiting "build, second half"
agents "w:p10,done,8,acme-w"
out="$(MCV_WATCH_NOW=2810 poll)"
expect "a second wait in a row: nothing" '[[ -z "$out" ]]' "$out"
out="$(MCV_WATCH_NOW=3300 poll)"
expect "the limit counts from the latest stop" '[[ -z "$out" ]]' "$out"
# A report after a wait is printed as usual and ends the wait.
say w "done" "pair clean"
out="$(MCV_WATCH_NOW=3500 poll)"
expect "a report during a wait is printed" '[[ $(count "$out") -eq 1 && "$out" == *"pair clean" ]]' "$out"
out="$(MCV_WATCH_NOW=9000 poll)"
expect "no stuck wait after the report" '[[ -z "$out" ]]' "$out"
unset MCV_WATCH_WAIT_LIMIT

# A worker that has said its piece (a question, done, failed, blocked) and
# has been sent nothing since owes the coordinator nothing: a later turn
# that ends without a report is not a stop to look at. Measured in a real
# run: a note sent right after a question, and Claude compacting an idle
# worker's context 55 minutes after its question, each gave a STOPPED.
# The journal says when a prompt was sent.
rm -rf "$MCV_HOME/acme/tasks" "$MCV_HOME/acme/journal.log"
export MCV_WATCH_WAIT_LIMIT=600
task s w:p12
agents "w:p12,working,1,acme-s"
sent 2000-01-01T00:00:00Z s
MCV_WATCH_NOW=1000 poll >/dev/null
say s needs-decision "Stash or a private ref?"
say s note "part 1 done; part 2 waits on the question"
agents "w:p12,done,2,acme-s"
out="$(MCV_WATCH_NOW=1010 poll)"
expect "a note right after a question does not turn the stop into STOPPED" \
  '[[ $(count "$out") -eq 1 && "$out" == *"needs-decision"* ]]' "$out"
agents "w:p12,working,3,acme-s"
MCV_WATCH_NOW=4000 poll >/dev/null
agents "w:p12,done,4,acme-s"
out="$(MCV_WATCH_NOW=4010 poll)"
expect "an idle worker's silent turn after its question (a compaction): nothing" '[[ -z "$out" ]]' "$out"
# The same with a wait announced after the question: no stuck wait later.
say s needs-decision "Run the real pair test?"
say s waiting "the answer to the question"
MCV_WATCH_NOW=4020 poll >/dev/null
agents "w:p12,working,5,acme-s"
MCV_WATCH_NOW=4030 poll >/dev/null
agents "w:p12,done,6,acme-s"
out="$(MCV_WATCH_NOW=4040 poll)"
expect "a wait announced for the user's answer: nothing" '[[ -z "$out" ]]' "$out"
out="$(MCV_WATCH_NOW=9000 poll)"
expect "and no stuck wait past the limit while the question is open" '[[ -z "$out" ]]' "$out"
# Once something is sent to it, a silent stop is a stop again.
sent 2999-01-01T00:00:00Z s
agents "w:p12,working,7,acme-s"
MCV_WATCH_NOW=9100 poll >/dev/null
agents "w:p12,done,8,acme-s"
out="$(MCV_WATCH_NOW=9110 poll)"
expect "after a prompt, a silent stop is STOPPED" \
  '[[ $(count "$out") -eq 1 && "$out" == *"state"$'"'"'\t'"'"'"done" ]]' "$out"
# A prompt that was refused sent nothing.
rm -f "$MCV_HOME/acme/journal.log"
printf '2999-01-01T00:00:00Z\tprompt\tacme/s\terror: worker acme/s is working\n' >>"$MCV_HOME/acme/journal.log"
say s "done" "committed"
MCV_WATCH_NOW=9200 poll >/dev/null
agents "w:p12,working,9,acme-s"
MCV_WATCH_NOW=9210 poll >/dev/null
agents "w:p12,done,10,acme-s"
MCV_WATCH_NOW=9220 poll >/dev/null
agents "w:p12,working,11,acme-s"
MCV_WATCH_NOW=9230 poll >/dev/null
agents "w:p12,done,12,acme-s"
out="$(MCV_WATCH_NOW=9240 poll)"
expect "a refused prompt does not count: a later silent turn after done is nothing" '[[ -z "$out" ]]' "$out"
# A worker that never reported is still a stop, prompt or not.
task s2 w:p13
agents "w:p12,done,12,acme-s|w:p13,working,1,acme-s2"
MCV_WATCH_NOW=9300 poll >/dev/null
agents "w:p12,done,12,acme-s|w:p13,done,2,acme-s2"
out="$(MCV_WATCH_NOW=9310 poll)"
expect "a worker with no report at all: a silent stop is STOPPED" \
  '[[ $(count "$out") -eq 1 && "$out" == *"acme/s2"*"state"$'"'"'\t'"'"'"done" ]]' "$out"
unset MCV_WATCH_WAIT_LIMIT

# A watcher restarted with --resume (the Monitor tool ended the last one)
# carries on where it stopped: nothing is shown again. Started without it,
# as for a new coordinator, the open questions are shown once more.
rm -rf "$MCV_HOME/acme/tasks"
task r w:p11
agents "w:p11,done,1,acme-r"
say r needs-decision "open question?"
runw() { # <output file> [--resume]
  MCV_WATCH_INTERVAL=0.2 env -u MCV_WATCH_STATE "$W" acme ${2:+"$2"} >"$1" 2>/dev/null &
  local p=$! i=0
  # A second from when it holds the lock, not from when it was started: on
  # a busy machine starting alone can take that long.
  while (( i < 50 )) && [[ "$(cat "$MCV_HOME/acme/watch.lock/pid" 2>/dev/null)" != "$p" ]]; do
    sleep 0.2
    i=$((i + 1))
  done
  sleep 1
  kill -TERM "$p"; wait "$p" 2>/dev/null
}
runw "$root/r1.out"
expect "first watcher shows the open question" 'grep -q "open question?" "$root/r1.out"' "$(cat "$root/r1.out")"
runw "$root/r2.out" --resume
expect "resumed watcher shows nothing again" '[[ ! -s "$root/r2.out" ]]' "$(cat "$root/r2.out")"
say r blocked "new since"
runw "$root/r3.out" --resume
expect "resumed watcher shows what is new" \
  'grep -q "new since" "$root/r3.out" && ! grep -q "open question?" "$root/r3.out"' "$(cat "$root/r3.out")"
runw "$root/r4.out"
expect "a fresh watcher shows the open question again" 'grep -q "open question?" "$root/r4.out"' "$(cat "$root/r4.out")"
out="$("$W" acme --bogus 2>&1)"; rc=$?
expect "an unknown option is refused" '[[ $rc -eq 2 ]]' "rc=$rc"
export MCV_WATCH_STATE="$root/state3"

unset MCV_WATCH_RAW
rm -rf "$MCV_HOME/acme/tasks" "$MCV_WATCH_STATE"/acme
task v w:p8
agents "w:p8,working,1,acme-v"
poll >/dev/null
say v needs-decision "Session or query string?"
say v note "halfway"
say v "done" "web!221 opened, not merged"
out="$(poll)"
expect "readable: a question carries its id" \
  '[[ "$(sed -n 1p <<<"$out")" == "mcvv · QUESTION q1 · Session or query string?" ]]' "$out"
expect "readable: no note" '[[ "$out" != *halfway* ]]' "$out"
expect "readable: done" '[[ "$(sed -n 2p <<<"$out")" == "mcvv · DONE · web!221 opened, not merged" ]]' "$out"
agents "w:p8,blocked,2,acme-v"
out="$(poll)"
expect "readable: a dialog is WAITING" '[[ "$out" == "mcvv · WAITING · a dialog is open in its pane" ]]' "$out"
agents "w:p8,working,3,acme-v"
out="$(poll)"
expect "readable: leaving it is RESUMED" '[[ "$out" == "mcvv · RESUMED · "* ]]' "$out"
sent 2999-01-01T00:00:00Z v
agents "w:p8,done,4,acme-v"
out="$(poll)"
expect "readable: a turn end with no report is STOPPED, telling to read the screen" \
  '[[ "$out" == "mcvv · STOPPED · "*"read its screen" ]]' "$out"
"$STATUS" --task acme/v pending q1 "query string" >/dev/null
agents "w:p8,working,5,acme-v"
poll >/dev/null
agents "w:p8,done,6,acme-v"
out="$(poll)"
expect "readable: a pending answer is DELIVER with its id" '[[ "$out" == "mcvv · DELIVER q1 · query string" ]]' "$out"
agents ""
out="$(poll)"
expect "readable: GONE" '[[ "$out" == "mcvv · GONE · "* ]]' "$out"

# The Monitor tool cuts a line at about 500 characters and a notification
# at about 3000 (measured: 400 arrived whole, 600 was cut; seven lines of
# 420 arrived, the eighth was cut). In a real run 13 of 22 questions were
# longer than a line, and the coordinator read the log again for each. A
# long text is printed over several lines, cut at characters, not bytes:
# joined with nothing between, the pieces give the text back.
rm -rf "$MCV_HOME/acme/tasks" "$MCV_WATCH_STATE"/acme
task x w:p20
agents "w:p20,working,1,acme-x"
poll >/dev/null
pieces() { sed -e '1s/^mcvx · [A-Z]* [a-z0-9]* · //' -e '2,$s/^  …//' <<<"$1" | tr -d '\n'; }   # the text back
longest() { jq -Rn '[inputs | length] | max' <<<"$1"; }
long="$(printf 'Keep the server message on the page as an alert, or the self-closing toast? %.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13)"
long="${long% }"
say x needs-decision "$long"
out="$(poll)"
expect "a long question comes over several lines, none past 450 characters" \
  '[[ $(count "$out") -ge 3 && $(longest "$out") -le 450 ]]' "lines=$(count "$out") longest=$(longest "$out")"
expect "its first line is the usual header, the others are marked as continuations" \
  '[[ "$(sed -n 1p <<<"$out")" == "mcvx · QUESTION q1 · Keep the server"* ]] && ! sed 1d <<<"$out" | grep -qv "^  …"' "$out"
expect "joined, the lines give the question back" '[[ "$(pieces "$out")" == "$long" ]]' "$(pieces "$out")"
thai="$(printf 'กรอบสองชั้นใน Authority Setting วัดแล้วมีกรอบจริงหรือเป็นของหน้าเทียบ %.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
thai="${thai% }"
say x needs-decision "$thai"
out="$(poll)"
expect "Thai text is cut between characters and comes back whole" \
  '[[ $(count "$out") -ge 2 && $(longest "$out") -le 450 && "$(pieces "$out")" == "$thai" ]]' \
  "lines=$(count "$out") longest=$(longest "$out")"
say x needs-decision "Session or query string?"
out="$(poll)"
expect "a short text stays on one line" '[[ "$out" == "mcvx · QUESTION q3 · Session or query string?" ]]' "$out"
huge="$(printf 'word%.0s ' $(seq 1 800))"
say x needs-decision "$huge"
out="$(poll)"
expect "a text past one notification is cut at 2600 characters and says where the rest is" \
  '[[ $(jq -Rs length <<<"$out") -le 2900 && "$(tail -1 <<<"$out")" == "  …(cut here: the full text is in the task'"'"'s status.log)" ]]' \
  "chars=$(jq -Rs length <<<"$out") last=$(tail -1 <<<"$out")"

# A worker at a dialog: the event carries what the dialog shows, so the
# coordinator need not read the screen (measured: one read for each of 28).
# The screen is the one a real worker showed at a push.
screen="$root/screen"
cat >"$screen" <<'EOF'
⏺ Bash(git push -u origin feat/3.2.2-customer-master-r5 2>&1 | tail -3)
  ⎿  Running…

────────────────────────────────────────────────────────────────────────
 Bash command
 Run shell command
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 git push -u origin feat/3.2.2-customer-master-r5 2>&1 | tail -3
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Ask rule Bash(git push *) overrides auto mode for this command.
 /permissions to let auto mode decide

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
EOF
agents "w:p20,blocked,2,acme-x"
out="$(STUB_SCREEN="$screen" poll)"
expect "WAITING carries the dialog as the screen shows it" \
  '[[ "$(sed -n 1p <<<"$out")" == "mcvx · WAITING · a dialog is open in its pane:" ]] \
   && grep -qxF "  | git push -u origin feat/3.2.2-customer-master-r5 2>&1 | tail -3" <<<"$out" \
   && grep -qxF "  | Do you want to proceed?" <<<"$out" && grep -qxF "  | 1. Yes" <<<"$out"' "$out"
expect "without the rules, the text above the dialog or the key hints" \
  '! grep -q "╌\|─\|Running\|Esc to cancel" <<<"$out" && ! sed 1d <<<"$out" | grep -qv "^  | "' "$out"
agents "w:p20,working,3,acme-x"
poll >/dev/null
printf 'no dialog rule on this screen\n' >"$screen"
agents "w:p20,blocked,4,acme-x"
out="$(STUB_SCREEN="$screen" poll)"
expect "a screen with no dialog on it: the plain line, to be read" \
  '[[ "$out" == "mcvx · WAITING · a dialog is open in its pane" ]]' "$out"
agents "w:p20,working,5,acme-x"
poll >/dev/null
agents "w:p20,blocked,6,acme-x"
out="$(poll)"
expect "a screen that cannot be read: the plain line" \
  '[[ "$out" == "mcvx · WAITING · a dialog is open in its pane" ]]' "$out"

# A long dialog keeps both ends: what it is about at the top, and at the
# bottom why it asks, the question and the answers on offer. Cut from the
# top only, 14 of 15 real dialogs lost an answer line and one lost the
# question (measured on screens of a real run).
agents "w:p20,working,7,acme-x"
poll >/dev/null
{
  printf '⏺ Bash(node check.js)\n\n'
  printf '────────────────────────────────────────────────────────────────────────\n'
  printf ' Bash command\n Check the saved session of each shop\n'
  printf '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\n'
  printf ' │ node - <<EOF\n'
  for i in $(seq 1 30); do printf ' │   step(%s);\n' "$i"; done
  printf ' │ EOF\n'
  printf '╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌\n'
  printf ' Dangerous rm operation not ruled out\n /permissions to let auto mode decide\n\n'
  printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and do not ask again for node commands in /work/tree\n   3. No\n\n'
  printf ' Esc to cancel · Tab to amend\n'
} >"$screen"
agents "w:p20,blocked,8,acme-x"
out="$(STUB_SCREEN="$screen" poll)"
expect "a long dialog keeps its top" \
  'grep -qxF "  | Bash command" <<<"$out" && grep -qxF "  | Check the saved session of each shop" <<<"$out"' "$out"
expect "and its bottom: the reason, the question and every answer" \
  'grep -qxF "  | Dangerous rm operation not ruled out" <<<"$out" && grep -qxF "  | Do you want to proceed?" <<<"$out" \
   && grep -qxF "  | 1. Yes" <<<"$out" && grep -qxF "  | 3. No" <<<"$out" \
   && grep -qF "  | 2. Yes, and do not ask again" <<<"$out"' "$out"
expect "the middle is left out, and one line says how much" \
  '[[ $(grep -c "^  | " <<<"$out") -le 13 ]] && grep -qE "^  \| \(2[0-9] lines of the dialog are not shown" <<<"$out" \
   && ! grep -qF "step(15)" <<<"$out"' "$out"
# A line wider than the pane's usual width is cut, so that a dialog never
# passes one notification by itself.
agents "w:p20,working,9,acme-x"
poll >/dev/null
{
  printf '────────────────────────────────────────────────────────────────────────\n Bash command\n'
  for i in $(seq 1 30); do printf ' %s\n' "$(printf 'x%.0s' $(seq 1 400))"; done
  printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n'
} >"$screen"
agents "w:p20,blocked,10,acme-x"
out="$(STUB_SCREEN="$screen" poll)"
expect "a dialog of very wide lines still fits one notification" \
  '[[ $(jq -Rs length <<<"$out") -le 2800 ]] && grep -qxF "  | 2. No" <<<"$out"' "chars=$(jq -Rs length <<<"$out")"

# The Monitor tool joins lines printed within 200 ms into one notification
# and cuts it at about 3000 characters (measured: of two 1500-character
# questions in one poll, the end of the second was lost, with nothing to
# say so). Events that would not fit together are printed apart.
rm -rf "$MCV_HOME/acme/tasks" "$MCV_WATCH_STATE"/acme
task x w:p20; task y w:p21; task z w:p22
agents "w:p20,working,1,acme-x|w:p21,working,1,acme-y|w:p22,working,1,acme-z"
poll >/dev/null
numbered() { local i s=""; for i in $(seq 1 300); do s="$s$1$(printf '%03d' "$i") "; done; printf '%sEND-%s' "$s" "$1"; }
say x needs-decision "$(numbered A)"
say y needs-decision "$(numbered B)"
say z needs-decision "Short one?"
# Each line with the time it arrived; a burst is a run of lines less than
# 200 ms apart, as the Monitor tool groups them.
out="$(poll | perl -MTime::HiRes=time -e '$| = 1; while (<STDIN>) { printf "%.3f\t%s", time, $_ }')"
bursts="$(awk -F'\t' 'NR > 1 && $1 - prev > 0.2 { n++ } { len[n + 0] += length($2) + 1; prev = $1 }
  END { for (i = 0; i <= n; i++) printf "%s ", len[i] }' <<<"$out")"
expect "two long questions in one poll come as separate bursts" \
  '[[ $(wc -w <<<"$bursts") -ge 2 ]]' "bursts: $bursts"
expect "no burst passes 2800 characters" \
  '! tr " " "\n" <<<"$bursts" | awk "\$1 > 2800 { bad = 1 } END { exit !bad }"' "bursts: $bursts"
expect "and nothing of any question is lost" \
  'grep -q "END-A" <<<"$out" && grep -q "END-B" <<<"$out" && grep -q "Short one?" <<<"$out"' "$out"
# Short events of one poll still come together: no wait between them.
say x note "nothing"
say x needs-decision "One?"
say y needs-decision "Two?"
out="$(poll | perl -MTime::HiRes=time -e '$| = 1; while (<STDIN>) { printf "%.3f\t%s", time, $_ }')"
bursts="$(awk -F'\t' 'NR > 1 && $1 - prev > 0.2 { n++ } { len[n + 0] += length($2) + 1; prev = $1 }
  END { for (i = 0; i <= n; i++) printf "%s ", len[i] }' <<<"$out")"
expect "short events of one poll come in one burst" '[[ $(wc -w <<<"$bursts") -eq 1 ]]' "bursts: $bursts"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
