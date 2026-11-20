#!/usr/bin/env bash
#
# mcv-herdr.sh: start, prompt, read and remove mcv worker sessions through herdr.
#
# A worker is a separate Claude Code session that herdr starts in its own
# terminal pane, inside a new git worktree. Every command, doctor included,
# must run inside a herdr pane.
#
# Worker states, as herdr reports them: working (busy), blocked (waiting at an
# approval or question dialog), done (stopped, output not yet viewed), idle
# (stopped), unknown (herdr cannot tell).
#
# Commands:
#   doctor
#       Check that herdr, its server, its Claude integration and jq are ready.
#       Prints {ok, mcv, herdr, server, integration}; mcv is this copy's version
#       (from ../.claude-plugin/plugin.json, "unknown" when there is none).
#       When a newer version is installed beside this copy (Claude Code keeps
#       each in a folder named after it, and a running session keeps the one
#       it started with), a field note says so and what to do; spawn's output
#       carries the same note.
#   spawn <project> <id> <repo-path> <new-branch> [--base <ref> | --existing] [--context <folder>] [-- <claude-args>...]
#       Fetch, then create a git worktree of <repo-path> on a branch that must
#       not exist yet, locally, on a remote or as a tag, in any letter case
#       (main, master, develop and a remote's own name are always refused,
#       and so is a name that would be a folder of another branch or hold
#       one, such as main/x), starting from <ref> (default: the default branch of
#       origin, or of the only remote when none is called origin, e.g.
#       origin/main; a repository with no remote uses its current HEAD;
#       several remotes and no origin need --base). A bare repository is
#       refused, and so is a <repo-path> that is not the top folder of its
#       checkout (a subfolder of it, or a plain folder inside another
#       repository, such as a home folder kept in git); the error names the
#       repository's top folder. The new branch has no upstream until the worker pushes it. One
#       spawn runs at a time per repository; a second one waits for the
#       first. herdr chooses the folder, under ~/.herdr/worktrees/, and labels
#       its workspace "<id> · mcv <project>". Then start
#       an idle Claude in it with MCV_TASK=<project>/<id> set. Send it work with `prompt`. Arguments after
#       `--` go to claude, e.g. -- --permission-mode default; mcv's own
#       --base and --context there are refused, and so are Claude's
#       --add-dir (it would let the worker edit that folder) and --settings
#       (it could override MCV_TASK), as --flag value or --flag=value. If Claude fails to
#       start (for example at the folder trust dialog, or because the shell
#       asked something first), the error ends with "its pane shows: " and the
#       pane's last lines, and the task is left in
#       place: once the user lets Claude through in its pane, `prompt` works;
#       otherwise run `remove` before reusing the id. <project>-<id> must not
#       be the name of another task or herdr agent.
#       --existing instead puts the worker on a branch already on the remote
#       (origin, or the only remote), such as an open merge request's branch
#       that needs review fixes: fetch, then a worktree on that branch at the
#       remote's tip, with the remote branch as its upstream, so a plain
#       `git push` updates the request. Refused: the remote's default branch
#       and main, master, develop; a branch the remote lacks; one another
#       task works on; a local branch of that name that is checked out
#       somewhere or has commits the remote lacks (one behind the remote is
#       moved up to it); --base with it. The worker is told the branch is
#       already on the remote and not to open another request. Prints
#       existing: true; remove keeps the branch, as it has an upstream.
#       Files the repository's .worktreeinclude names (.gitignore syntax),
#       such as a .env, are copied from <repo-path> into the worktree when the
#       worktree's git ignores them and has no file there (at most 100).
#       --context <folder> also lets the worker read that folder and loads its
#       CLAUDE.md, CLAUDE.local.md and skills: use it for the project root
#       when the repository is one of several inside it. Claude's file edits
#       there are denied, and the worker is told it is read-only. Refused: a
#       folder inside the repository, /, one holding the worktree, and a path
#       with [ ] * or ? (the deny rule is a pattern).
#   prompt <project>/<id> <text> [--answers <id>... | --order] [--no-wait] [--timeout <ms>]
#       Send text and wait until the worker stops (default 10 minutes). Prints
#       only the worker's new state; use `read` to see what it said. Refused
#       with no text (empty, or an option where the text goes), unless the
#       worker is idle or done, and for a worker whose Claude did
#       not load mcv's hooks (no rules-loaded marker from its SessionStart
#       hook: the plugin is not loaded there). With --no-wait, return as soon as
#       the worker has started (state working, or blocked at a dialog), within
#       seconds. Without it, when run from Claude Code's Bash tool, give the
#       tool a timeout longer than --timeout. Says so plainly when Claude has
#       exited in the worker's pane.
#       --answers <id>: the text answers question <id> (q1, q2, ...) or is the
#       queued order <id> (o1, o2, ...). Sent to a stopped worker, it is
#       recorded as answered (prints "answered": <id>). To a worker that is
#       working or at a dialog nothing is sent: the text is kept as pending
#       (prints "queued": <id>, exit 0), and mcv-watch prints it as a deliver
#       event when the worker stops. Refused, before anything is sent, for an
#       id that was never asked or queued, or is answered already. When the
#       send fails for another reason, nothing is recorded. A thing a done
#       left to the user (needs q<n>) has a question id and is answered the
#       same way. Given more than once, --answers makes one text answer
#       several ids in one send (prints them joined by spaces): the first
#       id's line holds the text and the others say "with <first id>". One
#       id that cannot take an answer, or an id named twice, refuses it all.
#       --order: the text is a new order that answers nothing. Sent to a
#       stopped worker as it is; for a busy one it is queued under a new
#       order id (prints "queued": o<n>), to be sent later with --answers.
#       Without either option a busy worker is refused, as before.
#   read <project>/<id> [<lines>]
#       Print the last lines of the worker's terminal (default 80), plain text,
#       also after Claude has exited there.
#   agents
#       Every herdr agent, not only mcv workers, one per line, tab-separated:
#       pane id, state, a counter that increases on every state change (compare
#       two calls to see whether anything changed), and the agent name (mcv
#       workers are named <project>-<id>; "-" when unnamed).
#   remove <project>/<id>
#       Close the worker, delete its worktree folder and the task's mcv state,
#       after copying the task's meta, status log and transcript paths to
#       <project>/history/<id>-<UTC time>/ (printed as "history").
#       Refused while the worker is working or at a dialog, and while the
#       worktree has uncommitted or untracked files, or git cannot read it;
#       ignored files are deleted with it. The branch is kept, as a local
#       branch (branch_kept); push it first if you need it. A branch still at
#       the commit it started from, with no upstream and on no remote, holds no
#       work and is deleted (branch_deleted). Once no worktree of the
#       repository is open, the workspace herdr opened for its main checkout
#       at a spawn is closed (closed_workspace), if it is still one idle
#       shell; one the user had open stays. Folders left empty (the project's
#       tasks folder, herdr's folder for the repository) are removed.
#       Also works after the user has closed the worker's herdr workspace.
#       It can be run again after it stopped half way and goes on from what
#       is left: a worktree git no longer lists, a folder left at its path
#       (deleted: it holds only what was written after git emptied it), a
#       herdr workspace still open (closed). Refused, saying so, while
#       something still writes into the worktree's folder (a dev server
#       started there): stop it and run remove again. Nothing is killed.
#       A task whose spawn was killed outright while herdr made its worktree
#       has no meta, only what spawn wrote down first (tasks/<id>/spawning):
#       remove then clears the worktree, its herdr workspace and, if it is
#       the spawn's own and still at its starting commit, the branch, and
#       prints leftover: true. Refused while that worktree has changes, or
#       while a spawn of the task is running. Spawning the task again clears
#       the same leftovers first.
#
# <project> and <id>: lowercase letters, digits, - and _; <project> starts with
# a letter; "<project>-<id>" is at most 32 characters (it becomes the herdr
# agent name).
#
# Output: one JSON object, except `read` and `agents`. Errors: one line on
# stderr, "mcv-herdr: <command>: <reason>", exit 1. Unknown command: this text,
# exit 2. Task state: ${MCV_HOME:-~/.claude/mcv}/<project>/tasks/<id>/meta
# (a relative MCV_HOME is taken from the current folder). spawn, prompt and
# remove add a line to <project>/journal.log, done or refused:
#   <UTC time>\t<command>\t<project>/<id>\tok: <what> | error: <reason>
# (prompt logs the length of the text, not the text).

# For maintainers: this is the only file in mcv that calls herdr. Every other
# mcv file goes through it, so a change in herdr's CLI is fixed here alone.

set -euo pipefail

MIN_HERDR="0.9.5"
MCV_HOME="${MCV_HOME:-$HOME/.claude/mcv}"
# spawn hands MCV_HOME to the worker, whose folder is its worktree: a
# relative path would point somewhere else there.
[[ "$MCV_HOME" == /* ]] || MCV_HOME="$PWD/$MCV_HOME"
PROJECT_RE='^[a-z][a-z0-9_-]*$'
ID_RE='^[a-z0-9][a-z0-9_-]*$'
CMD="${1:-}"

die() { printf 'mcv-herdr: %s: %s\n' "${CMD:-usage}" "$*" >&2; journal "error: $*"; exit 1; }

# The project's journal: one line per spawn, prompt and remove, done or
# refused, so a problem in a real run can be looked at afterwards. JTASK is
# set once the command has a checked task name; before that nothing is
# written. Only spawn may create the project's folder for it, so a mistyped
# project name leaves nothing behind. A line is short and appended in one
# write, so writers need no lock.
JTASK=""
JNEW=""
journal() {
  [[ -n "$JTASK" ]] || return 0
  local d="$MCV_HOME/${JTASK%%/*}"
  [[ -d "$d" || -n "$JNEW" ]] || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CMD" "$JTASK" \
    "$(printf '%s' "$1" | tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\037\177')" \
    >>"$d/journal.log" 2>/dev/null || true
}

need_herdr_pane() {
  [[ "${HERDR_ENV:-}" == 1 ]] \
    || die "not inside a herdr pane; start this Claude session from a herdr pane"
}

# Run herdr and return its stdout. On failure, turn herdr's JSON error
# (stderr, exit 1) into one line naming the herdr command.
h() {
  if h_try "$@"; then
    printf '%s' "$HOUT"
    return 0
  fi
  die "herdr $1 ${2:-}: $HERR_MSG"
}

# Like h, but sets variables instead of printing or dying: stdout in HOUT;
# on failure it returns 1, with herdr's error code in HERR_CODE and a
# one-line message in HERR_MSG. Call it directly, not inside $(...), or the
# variables are lost with the subshell.
HOUT=""
HERR_CODE=""
HERR_MSG=""
h_try() {
  local err rc=0
  err="$(mktemp)"
  HOUT="$(herdr "$@" 2>"$err")" || rc=$?
  if (( rc == 0 )); then
    rm -f "$err"
    return 0
  fi
  HERR_CODE="$(jq -r '.error.code // empty' <"$err" 2>/dev/null || true)"
  HERR_MSG="$(jq -r '.error | "\(.code): \(.message)"' <"$err" 2>/dev/null || true)"
  [[ -n "$HERR_CODE" ]] || HERR_MSG="$(head -1 "$err")"
  # herdr can fail without a word (killed, say); still name what happened.
  [[ -n "$HERR_MSG" ]] || HERR_MSG="exited with status $rc and no message"
  rm -f "$err"
  return 1
}

# One field of herdr's JSON output, or nothing when the output is not what
# this script expects, so callers fail with a sentence, not a jq error.
jfield() { jq -r "$2 // empty" <<<"$1" 2>/dev/null || true; }

# True when version $1 >= version $2. Compares the leading dotted numbers;
# a suffix such as -beta is ignored.
version_ge() {
  local IFS=.
  # Splitting on IFS=. is the point; both values are cut to digits and dots.
  # shellcheck disable=SC2206
  local -a a=(${1%%[^0-9.]*}) b=(${2%%[^0-9.]*})
  local i
  for i in 0 1 2; do
    local x="${a[$i]:-0}" y="${b[$i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

# Resolve "<project>/<id>" to its task folder; die when the task is unknown.
task_dir() {
  local task="$1"
  local p="${task%%/*}" i="${task#*/}"
  # The id becomes a folder that `remove` deletes, so nothing but a valid
  # name (no "..", no "/") gets that far.
  [[ "$task" == */* && "$p" =~ $PROJECT_RE && "$i" =~ $ID_RE ]] \
    || die "expected <project>/<id>, got '$task'"
  local d="$MCV_HOME/$p/tasks/$i"
  [[ -f "$d/meta" ]] || die "no task '$task' (nothing at $d/meta)"
  printf '%s' "$d"
}

# die() inside a command substitution only leaves the subshell, so every
# caller of task_dir assigns first and exits on failure before using it.

# Take over stale lock folder $1, whose pid file read $2 ("" for a lock with
# no pid) when it was found stale, and succeed when this process now holds
# it, its pid written. Two processes that both found it stale could
# otherwise each delete it: the first deletes it and makes its own, the
# second, which checked before that, deletes the first one's new lock, and
# both go ahead (measured: overlapping worktree creations in 2 of 5 rounds
# of 8 spawns on a stale repository lock). So this holds <lock>.takeover
# while it checks the lock again, deletes it and makes its own, and writes
# its pid before letting go, so the next one in sees a live holder. A lock
# with no pid must still be a minute old, or it is one just made. A
# takeover lock left by a process killed mid-takeover is cleared when its
# pid has exited and it is at least 2 seconds old, or it has no pid and is
# a minute old.
takeover() {
  local l="$1" seen="$2" t="$1.takeover" tseen tpid tat ok=1
  if ! mkdir "$t" 2>/dev/null; then
    tseen="$(cat "$t/pid" 2>/dev/null || true)"
    read -r tpid tat <<<"$tseen" || true
    if [[ "$tpid" =~ ^[0-9]+$ && "$tat" =~ ^[0-9]+$ ]] && (( $(date +%s) - tat >= 2 )) \
      && ! kill -0 "$tpid" 2>/dev/null; then
      rm -rf "$t"
    elif [[ -z "$tseen" && -n "$(find "$t" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rm -rf "$t"
    fi
    return 1
  fi
  printf '%s %s\n' "$$" "$(date +%s)" >"$t/pid"
  if [[ "$(cat "$l/pid" 2>/dev/null || true)" == "$seen" ]] \
    && { [[ -n "$seen" ]] || [[ -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; }; then
    rm -rf "$l"
    if mkdir "$l" 2>/dev/null; then
      printf '%s %s\n' "$$" "$(date +%s)" >"$l/pid"
      ok=0
    fi
  fi
  rm -rf "$t"
  return "$ok"
}

# Take lock folder $1, waiting up to $2 seconds (0: do not wait); fail when
# it is still held. The lock holds "<pid> <epoch seconds>". A lock whose pid
# has exited without releasing it (a crash) is taken over, but only if it is
# unchanged since it was read and at least 2 seconds old, so a lock another
# process has just taken is never deleted. A lock with no pid at all was
# left by a process killed between making it and writing the pid; it is
# taken over once the folder is a minute old, far longer than that gap.
# Taking over goes through takeover, so two processes that both found the
# lock stale never both hold it.
take_lock() {
  local l="$1" seen pid at i=0
  mkdir -p "$(dirname "$l")"
  until mkdir "$l" 2>/dev/null; do
    seen="$(cat "$l/pid" 2>/dev/null || true)"
    read -r pid at <<<"$seen" || true
    if [[ "$pid" =~ ^[0-9]+$ && "$at" =~ ^[0-9]+$ ]] && (( $(date +%s) - at >= 2 )) \
      && ! kill -0 "$pid" 2>/dev/null \
      && [[ "$(cat "$l/pid" 2>/dev/null || true)" == "$seen" ]]; then
      takeover "$l" "$seen" && break
    elif [[ -z "$seen" && -n "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ]] \
      && [[ ! -s "$l/pid" ]]; then
      takeover "$l" "" && break
    fi
    (( i++ < $2 )) || return 1
    sleep 1
  done
  printf '%s %s\n' "$$" "$(date +%s)" >"$l/pid"
}

# One spawn at a time per repository. Concurrent fetches and worktree
# creations race for the lock on the repository's .git/config and fail half
# way.
LOCK=""
lock_repo() {
  local l
  l="$MCV_HOME/.locks/$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
  take_lock "$l" 300 \
    || die "another spawn in $1 has held $l for 5 minutes; delete that folder if no spawn is running"
  LOCK="$l"
}
unlock_repo() {
  [[ -z "$LOCK" ]] || rm -rf "$LOCK"
  LOCK=""
}

# herdr keeps every worktree's workspace under a workspace for the
# repository's main checkout, and opens one when none is open (measured with
# herdr 0.9.5: one `worktree create` made both). That one is the user's when
# they had it open already; when a spawn made herdr open it, the last remove
# in the repository closes it again. The record of which one a spawn opened
# is a file per repository, since workers of several tasks share it.
repo_ledger() { printf '%s/.repo-workspaces/%s' "$MCV_HOME" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }

# Print the ids of the open workspaces of main checkout $1 (linked=false), or
# of its worktrees (linked=true), one per line. Paths are compared by -ef, as
# herdr may spell them differently.
repo_workspaces() {
  local id p
  h_try workspace list || return 0
  while IFS=$'\t' read -r id p; do
    [[ -n "$p" && "$p" -ef "$1" ]] && printf '%s\n' "$id"
  done < <(jq -r --argjson l "$2" '.result.workspaces[]?
      | select(.worktree.is_linked_worktree == $l)
      | [.workspace_id, (if $l then .worktree.repo_root else .worktree.checkout_path end)] | @tsv' \
      <<<"$HOUT" 2>/dev/null || true)
  return 0
}

# Close the main-checkout workspace a spawn made herdr open for repository
# $1, once no worktree of it is open any more, and print its id. Only a
# workspace left as herdr opened it is closed: one pane whose shell has
# nothing running in front of it. One the user has started using stays, and
# so does its record, for a later remove. Never fails: a failure here only
# leaves a workspace open.
close_repo_workspace() {
  local ledger ws out pane
  ledger="$(repo_ledger "$1")"
  ws="$(cat "$ledger" 2>/dev/null || true)"
  [[ -n "$ws" ]] || return 0
  [[ -z "$(repo_workspaces "$1" true)" ]] || return 0
  if ! grep -qxF "$ws" <<<"$(repo_workspaces "$1" false)"; then
    # The user closed it already.
    rm -f "$ledger"
    return 0
  fi
  h_try workspace get "$ws" || return 0
  [[ "$(jfield "$HOUT" .result.workspace.pane_count)" == 1 ]] || return 0
  h_try pane list --workspace "$ws" || return 0
  pane="$(jfield "$HOUT" '.result.panes[0].pane_id')"
  [[ -n "$pane" ]] && h_try pane process-info --pane "$pane" || return 0
  out="$(jq -r '.result.process_info | select(.foreground_process_group_id == .shell_pid) | "idle"' <<<"$HOUT" 2>/dev/null || true)"
  [[ "$out" == idle ]] || return 0
  h_try workspace close "$ws" || return 0
  rm -f "$ledger"
  printf '%s' "$ws"
}

# One spawn at a time per worker name, taken before anything is checked or
# made. Two spawns of one task, or of two tasks whose names join the same
# (a-b/c and a/b-c), would otherwise both pass the checks and overwrite each
# other's task.
CLAIM=""

# What a failed spawn undoes, on any exit (a signal included): the locks,
# then, until Claude was asked to start, the worktree and the task folder,
# and the branch if this spawn created it and no worktree holds it any more. Once
# Claude was asked to start, the task stays for `remove`.
NEW_ROOT=""
NEW_BRANCH=""
NEW_BRANCH_OWNED=""
NEW_WS=""
NEW_DIR=""
NEW_LABEL=""
spawn_cleanup() {
  local rc=$? ws p
  if (( rc != 0 )); then
    # A signal during worktree create stops this script only once herdr has
    # answered, before its answer is read: find the workspace by its label
    # and the worktree by the branch, which this spawn alone created.
    if [[ -z "$NEW_WS" && -n "$NEW_BRANCH" && -n "$NEW_LABEL" ]]; then
      NEW_WS="$(herdr workspace list 2>/dev/null \
        | jq -r --arg l "$NEW_LABEL" '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty' \
          2>/dev/null || true)"
    fi
    [[ -z "$NEW_WS" ]] || herdr worktree remove --workspace "$NEW_WS" >/dev/null 2>&1 || true
    [[ -z "$NEW_ROOT" ]] || close_repo_workspace "$NEW_ROOT" >/dev/null || true
    if [[ -n "$NEW_BRANCH" ]]; then
      p="$(git -C "$NEW_ROOT" worktree list --porcelain 2>/dev/null \
        | awk -v b="branch refs/heads/$NEW_BRANCH" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
      [[ -z "$p" ]] || git -C "$NEW_ROOT" worktree remove --force "$p" >/dev/null 2>&1 || true
    fi
    [[ -z "$NEW_DIR" ]] || rm -rf "$NEW_DIR"
    [[ -z "$NEW_BRANCH" || -z "$NEW_BRANCH_OWNED" ]] \
      || git -C "$NEW_ROOT" branch -D "$NEW_BRANCH" >/dev/null 2>&1 || true
  fi
  unlock_repo
  [[ -z "$CLAIM" ]] || rm -rf "$CLAIM"
}

# Is folder $2 a worktree that git lists for repository $1? Paths are
# compared by -ef, as git prints them with symlinks resolved.
is_worktree() {
  local p
  [[ -n "$2" && -d "$2" ]] || return 1
  while IFS= read -r p; do
    [[ "$p" -ef "$2" ]] && return 0
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  return 1
}

# Take worktree $2 of repository $1 and its herdr workspace $3 away, from
# whatever state an earlier try left them in: each step looks at what is
# there and does only what is still to do, so running it again after a
# failure goes on, and ends in the same place. $4 "force" removes a worktree
# git would keep. The caller has checked that the worktree holds no work.
#
# Why it is written this way (seen twice in real runs): a dev server left
# running in a worktree kept writing an ignored folder. git took the
# worktree out of its list but could not delete the folder, herdr reported
# that and kept its workspace, and no later remove could get past either
# the folder ("git cannot read") or herdr ("is not a working tree").
#
# A folder left at the worktree's path once git no longer lists it holds
# only what was written after git emptied it, so it is deleted. If it comes
# back, something still writes there: that is said, and nothing is killed.
drop_worktree() {
  local repo="$1" wt="$2" ws="$3" force="${4:-}" herr=""
  if [[ -n "$ws" ]] && ! h_try worktree remove --workspace "$ws"; then
    [[ "$HERR_CODE" == workspace_not_found ]] || herr="$HERR_MSG"
  fi
  if is_worktree "$repo" "$wt"; then
    git -C "$repo" worktree remove ${force:+--force} "$wt" >/dev/null 2>&1 || true
    ! is_worktree "$repo" "$wt" \
      || die "could not remove the worktree $wt${herr:+ (herdr: $herr)}; remove it with git worktree remove, then run this again"
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  if [[ -n "$wt" && -d "$wt" && ! "$wt" -ef "$repo" ]]; then
    rm -rf "$wt" 2>/dev/null || true
    # Long enough for a server that rewrites its cache to do so again.
    sleep 1
    [[ ! -d "$wt" ]] \
      || die "something still writes to $wt (a dev server started there?); stop it, then run this again"
  fi
  if [[ -n "$ws" && -n "$herr" ]] && h_try workspace get "$ws"; then
    h_try workspace close "$ws" \
      || die "the worktree is gone, but herdr could not close its workspace $ws ($HERR_MSG); close it in herdr, then run this again"
  fi
}

# Clear what a spawn killed outright (kill -9, a crash) left when it died
# between asking herdr for the worktree and writing the task: herdr finishes
# the worktree and the branch with nobody to record them, `remove` did not
# know them, and spawn refused the branch name as taken (measured). Before
# that call spawn writes $1/spawning, naming the repository, the branch, the
# workspace label, whether the branch is its own, and the commit the branch
# starts at; this removes what that file names, then the folder. The caller
# holds the task's claim, so no spawn of it is running.
#
# Leftovers that hold something are not thrown away: a worktree with changes
# is refused, and a branch that is not this spawn's own, or has moved from
# its starting commit, is kept. Prints "deleted" or "kept" for the branch.
clear_crashed() {
  local dir="$1" s root branch owned label base_sha ws p st kept=kept
  s="$(cat "$dir/spawning" 2>/dev/null || true)"
  root="$(jfield "$s" .repo)"
  branch="$(jfield "$s" .branch)"
  owned="$(jfield "$s" .owned)"
  label="$(jfield "$s" .label)"
  base_sha="$(jfield "$s" .base_sha)"
  if [[ -z "$root" || -z "$branch" || ! -d "$root" ]]; then
    rm -rf "$dir"
    printf '%s' "$kept"
    return 0
  fi
  worktree_of() {
    git -C "$root" worktree list --porcelain 2>/dev/null \
      | awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}'
  }
  p="$(worktree_of)"
  if [[ -n "$p" && -d "$p" ]]; then
    st="$(git -C "$p" status --porcelain 2>/dev/null)" \
      || die "refusing: git cannot read the state of $p, which a killed spawn left; check it by hand"
    [[ -z "$st" ]] \
      || die "refusing: $p, which a killed spawn left, has uncommitted changes; commit or discard them first"
  fi
  lock_repo "$root"
  ws=""
  if [[ -n "$label" ]]; then
    ws="$(herdr workspace list 2>/dev/null \
      | jq -r --arg l "$label" '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty' \
        2>/dev/null || true)"
  fi
  drop_worktree "$root" "$p" "$ws" force
  if [[ "$owned" == true && -n "$base_sha" ]] \
    && [[ "$(git -C "$root" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)" == "$base_sha" ]] \
    && git -C "$root" branch -D "$branch" >/dev/null 2>&1; then
    kept=deleted
  fi
  git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || kept=deleted
  close_repo_workspace "$root" >/dev/null || true
  unlock_repo
  rm -rf "$dir"
  printf '%s' "$kept"
}

# Copy into worktree $2 the files of main checkout $1 that its
# .worktreeinclude names (.gitignore syntax), keeping their paths, and print
# how many. On failure print the reason and return 1.
#
# The worktree's own git decides what is copied, not the main checkout's:
# the worktree is on the base branch, which may track a file the main
# checkout ignores, or not ignore it at all. Copying such a file would
# overwrite committed content or leave an untracked secret for `git add -A`.
# So a file is copied only when the worktree ignores it and has no file
# there yet. Only regular files are copied; a symlink would point elsewhere
# once moved. The list is meant for a few small files (an .env), so it is
# capped.
MAX_INCLUDES=100
copy_includes() {
  local root="$1" wt="$2" f
  local -a files=()
  if [[ ! -f "$root/.worktreeinclude" ]]; then
    echo 0
    return 0
  fi
  while IFS= read -r -d '' f; do
    [[ -f "$root/$f" && ! -L "$root/$f" && ! -e "$wt/$f" && ! -L "$wt/$f" ]] || continue
    files+=("$f")
  done < <(git -C "$root" ls-files -z --others --ignored \
             --exclude-from="$root/.worktreeinclude" 2>/dev/null \
           | git -C "$wt" check-ignore -z --stdin 2>/dev/null)
  if (( ${#files[@]} > MAX_INCLUDES )); then
    echo ".worktreeinclude names ${#files[@]} files, more than $MAX_INCLUDES; list only the few a worker needs (a dependency folder is installed, not copied)"
    return 1
  fi
  local err
  for f in ${files[@]+"${files[@]}"}; do
    err="$( { mkdir -p "$wt/$(dirname "$f")" && cp -p "$root/$f" "$wt/$f"; } 2>&1 )" \
      || { echo "could not copy $f from .worktreeinclude into the worktree: $(head -1 <<<"$err")"; return 1; }
  done
  echo "${#files[@]}"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# True when folder $1 is folder $2 or lies inside it. Each step up from $1
# is compared with $2 by device and inode, so letter case and symlinks in
# the spelling do not matter.
within() {
  local d
  d="$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)" || return 1
  while :; do
    [[ "$d" -ef "$2" ]] && return 0
    [[ "$d" == / ]] && return 1
    d="$(dirname "$d")"
  done
}

# Print the first ref of repository $1 that is branch $2 (given in lower
# case) in any letter case, locally, on any remote, or as a tag (git would
# find the name ambiguous), and succeed; fail when there is none.
branch_taken() {
  local ref
  while IFS= read -r ref; do
    case "$ref" in
      refs/heads/"$2"|refs/tags/"$2") ;;
      refs/remotes/*/"$2") [[ "${ref#refs/remotes/*/}" == "$2" ]] || continue ;;
      *) continue ;;
    esac
    printf '%s' "$ref"
    return 0
  done < <(git -C "$1" for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags | tr '[:upper:]' '[:lower:]')
  return 1
}

# Print the first branch of repository $1, local or on a remote, that branch
# $2 (lower case) would sit inside or hold as a folder (main and main/x, or
# feat and feat/taken), and succeed; fail when there is none. git cannot
# keep both, here or on the remote once pushed.
branch_clash() {
  local ref name
  while IFS= read -r ref; do
    case "$ref" in
      refs/heads/*) name="${ref#refs/heads/}" ;;
      refs/remotes/*/*) name="${ref#refs/remotes/*/}" ;;
      *) continue ;;
    esac
    if [[ "$2" == "$name"/* || "$name" == "$2"/* ]]; then
      printf '%s' "$ref"
      return 0
    fi
  done < <(git -C "$1" for-each-ref --format='%(refname)' refs/heads refs/remotes | tr '[:upper:]' '[:lower:]')
  return 1
}

# The top folder of the checkout at $1. A bare repository has none, and
# git's own refusal ("not a git repository") would send the user looking in
# the wrong place. $1 must be that top folder itself: git answers for any
# folder inside a checkout, so a plain folder under a home kept in a dotfiles
# repository would otherwise give the worker a worktree of the whole home.
# Compared by -ef, as git prints the path with symlinks resolved.
repo_root() {
  local top
  [[ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null)" != true ]] \
    || die "$1 is a bare repository, with no files to work on; give a checkout of it"
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository: $1"
  [[ "$top" -ef "$1" ]] \
    || die "$1 is not a repository's top folder but a folder inside the repository $top; give the repository's top folder"
  printf '%s\n' "$top"
}

# Remove a worktree herdr just created, and the task folder written for it,
# then fail, saying whether the removal worked.
abandon_worktree() {
  local ws="$1"
  shift
  NEW_WS=""
  [[ -z "$NEW_DIR" ]] || rm -rf "$NEW_DIR"
  NEW_DIR=""
  if herdr worktree remove --workspace "$ws" >/dev/null 2>&1; then
    die "$*; the worktree was removed"
  fi
  die "$*; removing the worktree failed too: close herdr workspace $ws, then run git worktree prune"
}

cmd_doctor() {
  need_herdr_pane
  [[ $# -eq 0 ]] || die "usage: doctor"
  command -v jq >/dev/null || die "jq not found; install jq"
  command -v herdr >/dev/null || die "herdr not found; install it from https://herdr.dev"

  local st client server_status server_version compatible
  st="$(h status --json)"
  client="$(jfield "$st" .client.version)"
  server_status="$(jfield "$st" .server.status)"
  server_version="$(jfield "$st" .server.version)"
  compatible="$(jfield "$st" .server.endpoint_compatible)"
  [[ -n "$client" && -n "$server_status" ]] \
    || die "herdr status gave unexpected output; is herdr >= $MIN_HERDR?"

  version_ge "$client" "$MIN_HERDR" || die "herdr $client is older than $MIN_HERDR; run: herdr update"
  [[ "$server_status" == running ]] \
    || die "herdr server is not running (status: $server_status); start herdr by running: herdr"
  [[ "$compatible" == true ]] \
    || die "herdr server $server_version does not match herdr $client; restart herdr after updating"
  version_ge "$server_version" "$MIN_HERDR" \
    || die "herdr server $server_version is older than $MIN_HERDR; restart herdr after updating"

  local integ
  integ="$(h integration status | grep '^claude:' || true)"
  [[ "$integ" =~ ^claude:\ current([[:space:]]|$) ]] \
    || die "herdr's Claude integration is not current (${integ:-missing}); run: herdr integration install claude"

  # The version of this copy, read beside it, so the coordinator can show
  # which install it runs; a session keeps the helpers it started with.
  local mcv
  mcv="$(jq -r '.version // empty' "$(dirname "${BASH_SOURCE[0]}")/../.claude-plugin/plugin.json" 2>/dev/null || true)"
  jq -cn --arg m "${mcv:-unknown}" --arg c "$client" --arg s "$server_version" --arg n "$(newer_note)" \
    '{ok: true, mcv: $m, herdr: $c, server: $s, integration: "current"} + (if $n == "" then {} else {note: $n} end)'
}

# Print a sentence when a newer mcv is installed beside this copy, nothing
# otherwise. Claude Code keeps each installed version in a folder named
# after it, and a running session keeps the folder it started with, through
# /clear too, while the workers it starts load the newest. The sentence
# says what to do, since the session that reads it follows an older skill
# that knows nothing of it. Only a folder named after its own version is
# taken for an installed copy; a checkout has no such neighbours.
newer_note() {
  local root own d v best=""
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || return 0
  own="$(jq -r '.version // empty' "$root/.claude-plugin/plugin.json" 2>/dev/null || true)"
  [[ "$own" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${root##*/}" == "$own" ]] || return 0
  for d in "${root%/*}"/*/; do
    d="${d%/}"
    v="${d##*/}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -f "$d/.claude-plugin/plugin.json" ]] || continue
    if [[ "$v" != "${best:-$own}" ]] && version_ge "$v" "${best:-$own}"; then best="$v"; fi
  done
  [[ -z "$best" ]] \
    || printf 'mcv %s is installed, but this session still runs %s and its skill. Tell the user: quit Claude Code and start it again to use %s (/clear does not switch).' "$best" "$own" "$best"
}

cmd_spawn() {
  need_herdr_pane
  [[ $# -ge 4 ]] || die "usage: spawn <project> <id> <repo-path> <new-branch> [--base <ref> | --existing] [--context <folder>] [-- <claude-args>...]"
  local project="$1" id="$2" repo="$3" branch="$4" base="" context="" existing=""
  shift 4
  # Sound names go in the journal from the start, refusals included; the
  # names are checked again, with their own messages, below.
  if [[ "$project" =~ $PROJECT_RE && "$id" =~ $ID_RE ]]; then JTASK="$project/$id"; JNEW=1; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)
        [[ $# -ge 2 && -n "$2" ]] || die "--base needs a ref, e.g. origin/main"
        base="$2"
        shift 2 ;;
      --existing) existing=1; shift ;;
      --context)
        [[ $# -ge 2 && -n "$2" ]] || die "--context needs a folder"
        [[ -z "$context" ]] || die "--context given twice"
        context="$(CDPATH='' cd -- "$2" 2>/dev/null && pwd -P)" || die "--context: no such folder: $2"
        [[ "$context" != / ]] || die "--context / would open the whole disk; give the project folder"
        # The deny rule is a path pattern: these characters would make it
        # match something other than the folder.
        case "$context" in
          *[][*?]*) die "--context $context: a path with [ ] * or ? cannot be kept read-only for the worker; use a folder without them" ;;
        esac
        shift 2 ;;
      --) shift; break ;;
      *) die "unknown option '$1'; Claude's own options go after --" ;;
    esac
  done
  [[ -z "$existing" || -z "$base" ]] \
    || die "--existing works on the branch as the remote has it; --base does not apply"
  local a
  for a in "$@"; do
    case "$a" in
      --base|--base=*|--context|--context=*|--existing) die "$a after --: mcv's options go before --, Claude's after" ;;
      # --add-dir would open a folder the context's deny rule does not
      # cover, and --settings could override MCV_TASK.
      --add-dir|--add-dir=*) die "$a after --: spawn refuses it, since the worker could edit that folder; use --context for a read-only folder" ;;
      --settings|--settings=*) die "$a after --: spawn refuses it, since it could override the MCV_TASK that ties the worker to its task" ;;
    esac
  done
  # The context is the folder around the repository. One inside it, or the
  # repository itself, adds nothing the worktree lacks. Compared by device
  # and inode (-ef), not by spelling: macOS file systems ignore case.
  if [[ -n "$context" ]]; then
    local repo_real
    repo_real="$(repo_root "$repo")" || exit 1
    within "$context" "$repo_real" \
      && die "--context $context is inside the repository; give the folder around it"
  fi
  # --branch also expands shorthands such as @{-1}, so the name must come back
  # unchanged; "@" alone is git's name for HEAD.
  if [[ "$branch" == @ || "$(git check-ref-format --branch "$branch" 2>/dev/null)" != "$branch" ]] \
    || ! git check-ref-format "refs/heads/$branch"; then
    die "'$branch' is not a valid branch name"
  fi

  [[ "$project" =~ $PROJECT_RE ]] \
    || die "project '$project': use lowercase letters, digits, - and _, starting with a letter"
  [[ "$id" =~ $ID_RE ]] \
    || die "id '$id': use lowercase letters, digits, - and _"
  local name="$project-$id"
  (( ${#name} <= 32 )) || die "'$name' is ${#name} characters; <project>-<id> may be at most 32"

  # Letter case is compared through tr, which knows only ASCII under some
  # locales (é and É would pass as different names), so names stay ASCII.
  ! printf '%s' "$branch" | LC_ALL=C grep -q '[^ -~]' \
    || die "'$branch': use ASCII letters, digits and - _ . / in branch names"

  # From here on, every exit (a signal included) runs the cleanup.
  trap spawn_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  take_lock "$MCV_HOME/.claims/$name" 0 \
    || die "another spawn of worker '$name' is running; if none is, delete $MCV_HOME/.claims/$name"
  CLAIM="$MCV_HOME/.claims/$name"

  local dir="$MCV_HOME/$project/tasks/$id"
  [[ ! -e "$dir/meta" ]] || die "task $project/$id already exists; pick another id or remove it first"
  # A folder without meta is what a crashed spawn or an old version left (a
  # status log, say); the new task must not inherit its question numbers.
  # One killed while herdr made its worktree also left that worktree and a
  # branch, which would make this spawn refuse the name as taken.
  [[ ! -f "$dir/spawning" ]] || clear_crashed "$dir" >/dev/null
  rm -rf "$dir"
  # Different tasks can join to the same name (a-b/c and a/b-c are both
  # a-b-c), and herdr may already run an agent of that name.
  local other
  other="$(grep -lF "\"agent\":\"$name\"" "$MCV_HOME"/*/tasks/*/meta 2>/dev/null | head -1 || true)"
  [[ -z "$other" ]] \
    || die "worker name '$name' is taken by task $(jq -r .task "$other"); pick another id"
  if herdr agent get "$name" >/dev/null 2>&1; then
    die "herdr already has an agent named '$name'; pick another id"
  fi

  local root
  root="$(repo_root "$repo")" || exit 1

  # herdr reuses an existing branch without complaint, even main, so a worker
  # could end up committing to it. Only a branch that exists nowhere, locally
  # or on a remote (checked again after the fetch below), is taken. Names
  # are compared ignoring case: on macOS a new loose ref MAIN is the same
  # file as main once main is packed, and commits to MAIN move main.
  local lc r
  lc="$(lower "$branch")"
  case "$lc" in
    main|master|develop) die "'$branch' is a shared branch; give the worker a new branch name" ;;
    refs/*|head|head/*) die "'$branch' is not a usable branch name; give a plain name such as fix/cart-total" ;;
  esac
  for r in $(git -C "$root" remote); do
    [[ "$lc" != "$(lower "$r")" ]] \
      || die "'$branch' is the name of the remote $r, which git would confuse with it; give a plain name such as fix/cart-total"
    [[ "$lc" != "$(lower "$r")"/* ]] \
      || die "'$branch' starts with the remote name $r; give a plain name such as fix/cart-total"
  done
  if [[ -z "$existing" ]]; then
    r="$(branch_taken "$root" "$lc")" \
      && die "branch '$branch' already exists as ${r#refs/} in $root; give the worker a new branch name"
    r="$(branch_clash "$root" "$lc")" \
      && die "branch '$branch' cannot sit beside ${r#refs/} in $root (one name would be a folder of the other); give another name"
  fi

  lock_repo "$root"
  NEW_ROOT="$root"

  # Start from the latest remote state, as a person would pull before
  # branching: fetch, then branch from --base, or from the default branch of
  # origin, or of the only remote when none is called origin. A repository
  # with no remote branches from its current HEAD. A --base that is not on a
  # remote (a local branch) is used as it is.
  local remote r
  if [[ -z "$base" ]]; then
    local -a remotes=()
    while IFS= read -r r; do [[ -z "$r" ]] || remotes+=("$r"); done < <(git -C "$root" remote)
    remote=""
    if git -C "$root" remote get-url origin >/dev/null 2>&1; then
      remote=origin
    elif (( ${#remotes[@]} == 1 )); then
      remote="${remotes[0]}"
    elif (( ${#remotes[@]} > 1 )); then
      die "$root has several remotes and none is called origin; pass --base <remote>/<branch>"
    fi
    if [[ -n "$remote" ]]; then
      git -C "$root" remote set-head "$remote" --auto >/dev/null 2>&1 || true
      base="$(git -C "$root" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
      # Falling back to the local HEAD here would start a stale branch quietly.
      [[ -n "$base" ]] \
        || die "cannot tell $remote's default branch in $root (offline, or nothing pushed there yet?); pass --base <ref>"
    fi
  fi
  # An existing branch is worked on as the remote has it: the remote branch
  # is the base. The remote's default branch is the one every worker starts
  # from, so it is never a worker's own, whatever it is called.
  if [[ -n "$existing" ]]; then
    [[ -n "$remote" ]] || die "--existing takes a branch already on a remote, and $root has none"
    [[ "$(lower "$base")" != "$(lower "$remote/$branch")" ]] \
      || die "'$branch' is $remote's default branch; give the worker a branch of its own"
    base="$remote/$branch"
  fi
  if [[ -n "$base" ]]; then
    remote="${base%%/*}"
    if git -C "$root" remote get-url "$remote" >/dev/null 2>&1; then
      git -C "$root" fetch --quiet "$remote" || die "git fetch $remote failed in $root"
    fi
    [[ -z "$existing" ]] || git -C "$root" show-ref --verify --quiet "refs/remotes/$base" \
      || die "branch '$branch' is not on $remote; --existing takes a branch already pushed there, such as an open merge request's"
    git -C "$root" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
      || die "base '$base' is not a commit in $root"
  fi
  local reuse="" owned=1
  if [[ -z "$existing" ]]; then
    r="$(branch_taken "$root" "$lc")" \
      && die "branch '$branch' already exists as ${r#refs/} in $root; give the worker a new branch name"
    r="$(branch_clash "$root" "$lc")" \
      && die "branch '$branch' cannot sit beside ${r#refs/} in $root (one name would be a folder of the other); give another name"
  else
    # Two workers on one branch would push over each other.
    other="$(jq -r --arg r "$root" --arg b "$branch" 'select(.repo == $r and .branch == $b) | .task' \
      "$MCV_HOME"/*/tasks/*/meta 2>/dev/null | head -1 || true)"
    [[ -z "$other" ]] || die "branch '$branch' is already worked on by task $other; send that worker the work, or remove it first"
    # A local branch of that name is used only when no work of it would be
    # lost or fought over: not checked out anywhere, and with nothing the
    # remote lacks. One behind the remote (left by an earlier worker, say)
    # is moved up to it first; herdr checks a local branch out as it is.
    local tip here
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
      r="$(git -C "$root" worktree list --porcelain \
        | awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
      [[ -z "$r" ]] || die "branch '$branch' is checked out in $r; switch that checkout to another branch first"
      tip="$(git -C "$root" rev-parse "refs/remotes/$base")"
      here="$(git -C "$root" rev-parse "refs/heads/$branch")"
      git -C "$root" merge-base --is-ancestor "$here" "$tip" \
        || die "local branch '$branch' in $root has commits $base lacks; push them or delete the local branch first"
      [[ "$here" == "$tip" ]] || git -C "$root" update-ref "refs/heads/$branch" "$tip" "$here" \
        || die "could not move local branch '$branch' up to $base"
      reuse=1
      owned=""
    fi
  fi

  # From here on, a branch named $branch was made by this spawn, unless
  # --existing found it already there (then a failure leaves it). The label
  # marks the workspace as mcv's in herdr's sidebar, beside the user's own,
  # with the word the coordinator's events start with. The task id comes
  # first because the sidebar shows only about 12 characters of a label.
  # The project stays at the end although the sidebar cuts it: the label is
  # how a cleanup finds the workspace of an interrupted spawn, and two
  # projects may use the same task id.
  local label="$id · mcv $project"
  NEW_BRANCH="$branch"
  NEW_BRANCH_OWNED="$owned"
  NEW_LABEL="$label"
  local created ws pane wt linked before opened hbase="$base"
  [[ -z "$reuse" ]] || hbase=""
  before="$(repo_workspaces "$root" false)"
  # Written before herdr is asked: killed outright while herdr works, this
  # spawn leaves a worktree and a branch with no task. This file lets
  # `remove`, or a spawn of the task again, find and clear them. It goes
  # once the task itself is written.
  mkdir -p "$dir"
  NEW_DIR="$dir"
  jq -cn --arg repo "$root" --arg branch "$branch" --arg label "$label" \
    --argjson owned "$([[ -n "$owned" ]] && echo true || echo false)" \
    --arg base_sha "$(git -C "$root" rev-parse -q --verify "${base:-HEAD}^{commit}" 2>/dev/null || true)" \
    '{repo: $repo, branch: $branch, label: $label, owned: $owned, base_sha: $base_sha}' >"$dir/spawning"
  created="$(h worktree create --cwd "$root" --branch "$branch" ${hbase:+--base "$hbase"} \
    --label "$label" --no-focus)"
  # A main-checkout workspace that was not open before was opened for this
  # spawn; the last remove in the repository closes it.
  opened="$(repo_workspaces "$root" false | grep -vxF -e "${before:-}" -e '' | head -1 || true)"
  if [[ -n "$opened" ]]; then
    mkdir -p "$(dirname "$(repo_ledger "$root")")" 2>/dev/null \
      && printf '%s\n' "$opened" >"$(repo_ledger "$root")" 2>/dev/null || true
  fi
  ws="$(jfield "$created" .result.workspace.workspace_id)"
  pane="$(jfield "$created" .result.root_pane.pane_id)"
  wt="$(jfield "$created" .result.worktree.path)"
  linked="$(jfield "$created" .result.workspace.worktree.is_linked_worktree)"
  [[ -n "$ws" ]] \
    || die "herdr worktree create gave no workspace id; look in herdr for a workspace labelled '$label' and close it"
  NEW_WS="$ws"
  [[ -n "$pane" && -n "$wt" && -d "$wt" ]] \
    || abandon_worktree "$ws" "herdr worktree create gave unexpected output"

  # The task is written as soon as the worktree exists, so a spawn killed
  # from here on leaves a task `remove` can clean up, not a stray worktree.
  # While Claude starts, which can take a minute, its pane is not in herdr's
  # agent list yet; the "starting" marker stops mcv-watch from reporting the
  # worker gone. It stays if Claude fails to start, until `remove`.
  local copied=0 created_at base_sha
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The commit the branch starts at: remove deletes a branch still there,
  # which holds no work.
  base_sha="$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null || true)"
  mkdir -p "$dir"
  NEW_DIR="$dir"
  : >"$dir/starting"
  write_meta() {
    local meta tmp
    meta="$(jq -cn --arg task "$project/$id" --arg agent "$name" --arg ws "$ws" --arg pane "$pane" \
      --arg wt "$wt" --arg repo "$root" --arg branch "$branch" --arg base "${base:-HEAD}" \
      --arg base_sha "$base_sha" --argjson existing "$([[ -n "$existing" ]] && echo true || echo false)" \
      --arg context "$context" --argjson copied "$copied" --arg created "$created_at" \
      '{task: $task, agent: $agent, workspace_id: $ws, pane_id: $pane, worktree: $wt,
        repo: $repo, branch: $branch, base: $base, base_sha: $base_sha, existing: $existing,
        context: $context, copied: $copied, created: $created}')"
    # Written whole, then renamed, so mcv-watch never reads half a file.
    tmp="$(mktemp "$dir/.meta.XXXXXX")"
    printf '%s\n' "$meta" >"$tmp"
    mv "$tmp" "$dir/meta"
  }
  write_meta
  rm -f "$dir/spawning"

  # A worker must never run in the user's own checkout. A separate worktree
  # has its own git dir, distinct from the repository's shared one.
  local own common
  own="$(cd "$wt" && cd "$(git rev-parse --git-dir)" && pwd -P)" \
    || abandon_worktree "$ws" "$wt is not a git worktree"
  common="$(cd "$wt" && cd "$(git rev-parse --git-common-dir)" && pwd -P)" \
    || abandon_worktree "$ws" "$wt is not a git worktree"
  if [[ "$linked" != true || "$own" == "$common" ]]; then
    abandon_worktree "$ws" "refusing: herdr opened $wt, which is the repository's main checkout, not a separate worktree"
  fi

  # The branch is created from a remote-tracking ref, so git makes that ref
  # its upstream (origin/main). A plain `git push` or `git pull` in the worker
  # would then target the base branch. The branch has no upstream until the
  # worker pushes it. An existing branch is the other way round: its
  # upstream is its own remote branch, so a plain push updates the merge
  # request, and the worktree must start exactly at the remote's tip.
  if [[ -n "$existing" ]]; then
    [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" == "$(git -C "$root" rev-parse "refs/remotes/$base")" \
       && "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$branch" ]] \
      || abandon_worktree "$ws" "herdr did not check out '$branch' at $base"
    git -C "$wt" branch --set-upstream-to="$base" "$branch" >/dev/null 2>&1 \
      || abandon_worktree "$ws" "could not set the upstream of '$branch' to $base in $wt"
  else
    git -C "$wt" branch --unset-upstream "$branch" >/dev/null 2>&1 || true
    if [[ -n "$(git -C "$wt" config "branch.$branch.merge" || true)" ]]; then
      abandon_worktree "$ws" "could not clear the upstream of '$branch' in $wt"
    fi
  fi
  unlock_repo

  # A context that holds the worktree (the home folder, say) would forbid the
  # worker its own files, since the context is read-only to it.
  if [[ -n "$context" ]] && within "$wt" "$context"; then
    abandon_worktree "$ws" "--context $context holds the worker's own worktree ($wt); give the project folder"
  fi

  # Files git ignores, so the worktree lacks them, but the worker needs
  # (a test account's .env, say): the repository lists them in
  # .worktreeinclude, as Claude Code's own worktrees do, and they are copied
  # from the main checkout.
  local out
  out="$(copy_includes "$root" "$wt")" || abandon_worktree "$ws" "$out"
  copied="$out"
  write_meta

  # From here on the task stays, even if Claude fails to start: `remove`
  # cleans it up, and the branch is held by its worktree.
  NEW_WS=""
  NEW_DIR=""
  NEW_BRANCH=""

  # MCV_TASK goes in through Claude's own settings, not an export typed into
  # the pane's shell first. herdr still types the whole claude command line
  # at the pane's shell prompt, so it lands in that shell's history; it holds
  # only the task name and paths, never a secret. MCV_HOME goes with it: the
  # worker's environment comes from herdr, not from this session, and its
  # status log must land where this session's watcher looks.
  #
  # With --context, the worker also sees that folder (the project root, when
  # the repository is one of several in it): --add-dir opens it, and the env
  # variable makes Claude load its CLAUDE.md and CLAUDE.local.md as well;
  # its skills come with --add-dir alone. --add-dir takes several folders,
  # so it goes before --settings, which ends its list. --add-dir also lets
  # Claude edit there, so a deny rule keeps its file-editing tools out of
  # the context ("//" starts an absolute path in a permission rule). Bash
  # is not covered by it; the worker's rules say read-only as well.
  local settings
  local -a ctx_args=()
  settings="$(jq -cn --arg t "$project/$id" --arg h "$MCV_HOME" --arg c "$context" \
    '{env: ({MCV_TASK: $t, MCV_HOME: $h}
      + (if $c == "" then {} else {CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: "1"} end))}
     + (if $c == "" then {} else {permissions: {deny: ["Edit(/" + $c + "/**)"]}} end)')"
  [[ -z "$context" ]] || ctx_args=(--add-dir "$context")
  if ! h_try agent start "$name" --kind claude --pane "$pane" --timeout 60000 \
    -- ${ctx_args[@]+"${ctx_args[@]}"} --settings "$settings" ${1+"$@"}; then
    # herdr types the claude command at the pane's shell prompt, so anything
    # the shell asks first (an update prompt, say) takes part of it, and herdr
    # only reports a timeout. The pane's last lines show what happened.
    local msg="$HERR_MSG" screen=""
    if h_try pane read "$pane" --source recent-unwrapped --lines 20; then
      screen="$(printf '%s\n' "$HOUT" | sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -n 4 \
        | awk 'NR > 1 { printf " / " } { printf "%s", $0 }')"
    fi
    die "herdr agent start: $msg${screen:+; its pane shows: $screen}"
  fi
  rm -f "$dir/starting"

  if [[ -n "$existing" ]]; then
    journal "ok: existing branch $branch at $base, worktree $wt${context:+, context $context}"
  else
    journal "ok: branch $branch from ${base:-HEAD}, worktree $wt${context:+, context $context}"
  fi
  # A worker loads the newest installed mcv; say so when this session runs
  # an older one, here where the two versions start to work together.
  jq -c --arg n "$(newer_note)" \
    '{task, agent, worktree, branch, base, existing, context, copied} + (if $n == "" then {} else {note: $n} end)' "$dir/meta"
}

cmd_prompt() {
  need_herdr_pane
  [[ $# -ge 2 ]] || die "usage: prompt <project>/<id> <text> [--answers <id> | --order] [--no-wait] [--timeout <ms>]"
  local task="$1" text="$2" timeout=600000 nowait="" answers="" order=""
  shift 2
  # A forgotten text would otherwise send an option word, or nothing, and
  # then wait up to ten minutes for the reply.
  case "$text" in
    --no-wait|--timeout|--answers|--order) die "the text is missing ('$text' is an option); usage: prompt <project>/<id> <text> [--answers <id> | --order] [--no-wait] [--timeout <ms>]" ;;
  esac
  [[ "$text" =~ [^[:space:]] ]] || die "no text to send; usage: prompt <project>/<id> <text> [--answers <id> | --order] [--no-wait] [--timeout <ms>]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-wait) nowait=1; shift ;;
      --timeout)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--timeout needs a number of milliseconds"
        timeout="$2"
        shift 2 ;;
      --answers)
        [[ $# -ge 2 && "$2" =~ ^[qo][1-9][0-9]*$ ]] \
          || die "--answers needs the id of a question (q1, q2, ...) or of a queued order (o1, o2, ...)"
        [[ " $answers " != *" $2 "* ]] || die "--answers names $2 twice"
        answers="${answers:+$answers }$2"
        shift 2 ;;
      --order) order=1; shift ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  [[ -z "$answers" || -z "$order" ]] || die "--answers and --order do not go together: a text answers something asked or queued, or is a new order"

  local d name status
  d="$(task_dir "$task")" || exit 1
  JTASK="$task"
  # What became of an answer or an order is recorded here, by the one
  # command that knows whether the text went in: answered once it is sent,
  # pending when the worker is busy (the watcher then prints it as a deliver
  # event when the worker stops). Left to a second command, the record was
  # written after a refused send (seen in a real run). The status log stays
  # mcv-status's to write; it is asked first whether the id can take an
  # answer, so that nothing is sent that could not be recorded.
  #
  # One text may answer several ids (--answers given more than once): it is
  # sent once. The first id's line holds the text and the others say "with
  # <first id>", so a queued text comes back from the watcher once, not once
  # for each id. Every id is checked before anything is sent or written.
  local st_bin a first=""
  st_bin="$(dirname "${BASH_SOURCE[0]}")/mcv-status"
  for a in $answers; do
    "$st_bin" --task "$task" open "$a" || exit 1
  done
  name="$(jfield "$(cat "$d/meta")" .agent)"
  [[ -n "$name" ]] || die "task $task has a damaged meta file ($d/meta)"
  # When Claude exits in its pane, herdr either drops the agent
  # (agent_not_found) or still lists it as done but refuses prompts
  # (agent_not_ready, or agent_not_running from newer herdr). All mean the
  # same to the coordinator.
  local gone_msg="worker $task is not running Claude any more (it exited, or never finished starting); read its screen, then remove it"
  if ! h_try agent get "$name"; then
    [[ "$HERR_CODE" != agent_not_found && "$HERR_CODE" != agent_not_running ]] || die "$gone_msg"
    die "herdr agent get: $HERR_MSG"
  fi
  status="$(jfield "$HOUT" .result.agent.agent_status)"
  [[ -n "$status" ]] || die "herdr agent get gave unexpected output"
  if [[ "$status" != idle && "$status" != "done" ]]; then
    # Behind Claude's folder trust question herdr reports idle or blocked,
    # and the SessionStart hook has not run yet.
    [[ -f "$d/rules-loaded" ]] \
      || die "worker $task is $status and has not started its session yet: if its pane shows Claude's folder trust question, pick Yes there and prompt again"
    if [[ -n "$answers$order" ]]; then
      local kept="$answers"
      if [[ -n "$order" ]]; then
        kept="$("$st_bin" --task "$task" pending - "$text")" || exit 1
      else
        for a in $answers; do
          "$st_bin" --task "$task" pending "$a" "${first:+with }${first:-$text}" || exit 1
          first="${first:-$a}"
        done
      fi
      journal "ok: worker is $status, nothing sent; kept as pending $kept"
      jq -cn --arg s "$status" --arg k "$kept" '{state: $s, queued: $k}'
      return 0
    fi
    die "worker $task is $status; prompt is only sent to a worker that has stopped (idle or done)"
  fi
  # mcv's SessionStart hook leaves this marker. Without it the worker's
  # Claude did not load the mcv plugin, so it has no git rules, may use
  # AskUserQuestion and never writes the status log: give it no work.
  # herdr reports a worker still at Claude's folder trust question as idle,
  # and Claude runs the hook only once past it, so that is checked first.
  [[ -f "$d/rules-loaded" ]] \
    || die "worker $task has no mcv worker rules yet: if its pane shows Claude's folder trust question, pick Yes there and prompt again; otherwise the mcv plugin is not loaded in its Claude session (install it for your user, or spawn with -- --plugin-dir <mcv folder>), so remove it and spawn again"

  # Return as soon as the worker has started (or stopped at a dialog); herdr
  # fails the call if neither happens within 15 seconds.
  local -a waitopts=(--timeout "$timeout")
  [[ -z "$nowait" ]] || waitopts=(--until working --until blocked --timeout 15000)
  if ! h_try agent prompt "$name" "$text" --wait "${waitopts[@]}"; then
    [[ "$HERR_CODE" != agent_not_ready && "$HERR_CODE" != agent_not_running ]] || die "$gone_msg"
    die "herdr agent prompt: $HERR_MSG"
  fi
  # A worker that failed to start (e.g. at a trust dialog) and was then let
  # through by the user has started after all.
  rm -f "$d/starting"
  status="$(jfield "$HOUT" .result.agent.agent_status)"
  # The text itself is in the worker's transcript; its length is enough here.
  for a in $answers; do
    "$st_bin" --task "$task" answered "$a" "${first:+with }${first:-$text}" \
      || die "the text was sent to $task, but could not be recorded as answered $a; record it with mcv-status"
    first="${first:-$a}"
  done
  journal "ok: sent ${#text} characters, state ${status:-unknown}${answers:+, answered $answers}"
  jq -cn --arg s "${status:-unknown}" --arg a "$answers" \
    '{state: $s} + (if $a == "" then {} else {answered: $a} end)'
}

cmd_read() {
  need_herdr_pane
  [[ $# -ge 1 && $# -le 2 ]] || die "usage: read <project>/<id> [<lines>]"
  [[ "${2:-80}" =~ ^[1-9][0-9]*$ ]] || die "lines must be a number, got '$2'"
  # Read the pane, not the agent: the screen stays readable after Claude has
  # exited and herdr has dropped the agent.
  local d pane
  d="$(task_dir "$1")" || exit 1
  pane="$(jfield "$(cat "$d/meta")" .pane_id)"
  [[ -n "$pane" ]] || die "task $1 has a damaged meta file ($d/meta)"
  h pane read "$pane" --source recent-unwrapped --lines "${2:-80}"
}

cmd_agents() {
  need_herdr_pane
  [[ $# -eq 0 ]] || die "usage: agents"
  local out
  out="$(h agent list)"
  jq -r '.result.agents[]
    | [.pane_id, .agent_status, (.state_change_seq // 0 | tostring), (.name // "-")] | @tsv' \
    <<<"$out" 2>/dev/null || die "herdr agent list gave unexpected output"
}

# Copy a task's record from its folder $1 into a new folder $2.
keep_history() {
  mkdir -p "$2" 2>/dev/null || return 1
  local f
  for f in meta status.log transcripts; do
    [[ ! -f "$1/$f" ]] || cp -p "$1/$f" "$2/" 2>/dev/null || return 1
  done
}

cmd_remove() {
  need_herdr_pane
  [[ $# -eq 1 ]] || die "usage: remove <project>/<id>"
  local dir m wt ws branch repo
  # A spawn killed while herdr made its worktree wrote no task, only what it
  # was about to make; that is cleared here. The claim shows no spawn of the
  # task is still running.
  local lp="${1%%/*}" li="${1#*/}" left kept
  left="$MCV_HOME/$lp/tasks/$li"
  if [[ "$1" == */* && "$lp" =~ $PROJECT_RE && "$li" =~ $ID_RE && ! -f "$left/meta" && -f "$left/spawning" ]]; then
    JTASK="$1"
    take_lock "$MCV_HOME/.claims/$lp-$li" 0 \
      || die "a spawn of $1 is still running; wait for it, or delete $MCV_HOME/.claims/$lp-$li if none is"
    CLAIM="$MCV_HOME/.claims/$lp-$li"
    trap 'unlock_repo; [[ -z "$CLAIM" ]] || rm -rf "$CLAIM"' EXIT
    branch="$(jq -r '.branch // empty' "$left/spawning" 2>/dev/null || true)"
    kept="$(clear_crashed "$left")" || exit 1
    rmdir "$(dirname "$left")" 2>/dev/null || true
    journal "ok: cleared what a spawn killed while creating the worktree left, branch $branch $kept"
    jq -cn --arg b "$branch" --arg k "$kept" \
      '{removed: true, leftover: true} + (if $k == "kept" then {branch_kept: $b} else {branch_deleted: $b} end)'
    return 0
  fi
  dir="$(task_dir "$1")" || exit 1
  JTASK="$1"
  m="$(cat "$dir/meta")"
  wt="$(jfield "$m" .worktree)"
  ws="$(jfield "$m" .workspace_id)"
  branch="$(jfield "$m" .branch)"
  repo="$(jfield "$m" .repo)"
  [[ -n "$wt" && -n "$ws" && -n "$repo" ]] || die "task $1 has a damaged meta file ($dir/meta)"
  # A working worker's tree can be clean for a moment; removing it then
  # would kill the work in progress. A worker herdr no longer knows is fine.
  local name status
  name="$(jfield "$m" .agent)"
  if [[ -n "$name" ]]; then
    if h_try agent get "$name"; then
      status="$(jfield "$HOUT" .result.agent.agent_status)"
      [[ "$status" != working && "$status" != blocked ]] \
        || die "worker $1 is $status; let it stop (or stop it in its herdr pane), then remove it"
    elif [[ "$HERR_CODE" != agent_not_found && "$HERR_CODE" != agent_not_running ]]; then
      die "herdr agent get: $HERR_MSG"
    fi
  fi
  # Unsure counts as dirty: a worktree git cannot read is not deleted. A
  # folder git no longer lists is what an earlier remove left half way; it
  # was checked then, and drop_worktree deals with it.
  if is_worktree "$repo" "$wt"; then
    local st
    st="$(git -C "$wt" status --porcelain 2>/dev/null)" \
      || die "refusing: git cannot read the state of $wt; check it by hand"
    [[ -z "$st" ]] || die "refusing: $wt has uncommitted changes; commit or discard them first"
  fi
  # herdr removes the worktree with its workspace; when the user has already
  # closed that workspace, or an earlier remove stopped half way, what is
  # left is taken away by git and by closing the workspace.
  drop_worktree "$repo" "$wt" "$ws"
  # The task's record outlives it: its meta, status log and the paths of
  # its worker's transcripts, for looking back at a run. If they cannot be
  # kept, the task's state stays where it is.
  local hist
  hist="$MCV_HOME/${1%%/*}/history/${1#*/}-$(date -u +%Y%m%dT%H%M%SZ)"
  [[ ! -e "$hist" ]] || hist="$hist-$$"
  keep_history "$dir" "$hist" \
    || die "the worktree is removed, but the task's record could not be copied to $hist; its state stays at $dir"
  rm -rf "$dir"
  # Folders this task's creation left that are now empty: the project's
  # tasks folder after its last task, and herdr's per-repository worktree
  # folder after its last worktree. rmdir removes only an empty folder, so
  # one still in use (another task) stays, and so does the project's
  # folder, which holds its journal and history.
  rmdir "$(dirname "$dir")" 2>/dev/null || true
  rmdir "$(dirname "$wt")" 2>/dev/null || true

  # A branch still at the commit it started from holds no work, and kept, it
  # would block a new spawn under the same name (seen when a first spawn
  # failed to start Claude). It goes only when it never moved, has no
  # upstream and no remote has a branch of that name; anything else is kept.
  # A task from before 0.2.1 has no base commit recorded, so its branch stays.
  local base_sha kept="kept" closed
  base_sha="$(jfield "$m" .base_sha)"
  if [[ -n "$base_sha" && -n "$branch" ]] \
    && [[ "$(git -C "$repo" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null || true)" == "$base_sha" ]] \
    && [[ -z "$(git -C "$repo" config "branch.$branch.merge" 2>/dev/null || true)" ]] \
    && [[ -z "$(git -C "$repo" for-each-ref --format=x "refs/remotes/*/$branch" 2>/dev/null || true)" ]] \
    && git -C "$repo" branch -D "$branch" >/dev/null 2>&1; then
    kept="deleted"
  fi
  closed="$(close_repo_workspace "$repo")"

  local note="branch $branch $kept"
  [[ "$kept" == kept ]] || note="$note (no commits past its base)"
  journal "ok: $note${closed:+, closed repository workspace $closed}, history $hist"
  jq -cn --arg b "$branch" --arg k "$kept" --arg h "$hist" --arg c "$closed" \
    '{removed: true} + (if $k == "kept" then {branch_kept: $b} else {branch_deleted: $b} end)
     + {history: $h} + (if $c == "" then {} else {closed_workspace: $c} end)'
}

case "$CMD" in
  doctor|spawn|prompt|read|agents|remove)
    shift
    "cmd_$CMD" "$@" ;;
  *)
    awk 'NR >= 3 && /^# For maintainers/ { exit } NR >= 3' "${BASH_SOURCE[0]}" \
      | sed 's/^#$//; s/^# //' >&2
    exit 2 ;;
esac
