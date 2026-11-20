#!/usr/bin/env bash
#
# Stand-in for the herdr command in spawn and remove tests. It does the git
# work herdr does, for real, so git behaves as it does under herdr:
#   worktree create --cwd <repo> --branch <b> [--base <ref>] --label <l> --no-focus
#       runs `git worktree add -b`, which makes a remote-tracking base the
#       branch's upstream, as herdr's worktree create does; a local branch
#       that already exists is checked out as it is, also as herdr does.
#   worktree remove --workspace <ws>
#   agent start <name> ...   adds <name> to FAKE_DIR/agents and runs mcv's
#                            SessionStart hook with the env from --settings,
#                            as Claude with the plugin loaded does
#                            (FAKE_NOHOOKS=1: as Claude without the plugin)
#   agent get <name>         idle (or FAKE_AGENT_STATE) if <name> is in FAKE_DIR/agents,
#                            else agent_not_found
#   agent prompt <name> ...  reports working
#   pane read <pane> ...     prints "screen of <pane>"
# State lives in FAKE_DIR. Every call appends its arguments to FAKE_DIR/calls.
# FAKE_FAIL=create makes worktree create fail after creating the branch, as a
# git lock failure half way does; FAKE_FAIL=start makes agent start fail;
# FAKE_FAIL=notready makes agent prompt fail as it does once Claude has exited;
# FAKE_FAIL=notrunning with the code newer herdr gives for that.
# FAKE_FAIL=partial makes worktree create report a workspace id but no pane;
# FAKE_FAIL=garbage makes it print something that is not JSON (both after
# creating the worktree).
#   workspace list           the workspaces worktree create made, with their labels,
#                            and the main-checkout ones, as herdr lists them
#   (FAKE_FAIL_REMOVE=1 makes worktree remove fail)
# Repository workspaces: herdr keeps a worktree's workspace under one for the
# repository's main checkout and opens that one when it is not open (measured
# with herdr 0.9.5). worktree create does the same here: ws-main-<repo folder>,
# kept in FAKE_DIR/main/. FAKE_MAIN_OPEN=<repo path> opens one first, as a
# user would.
#   workspace get <ws>       pane_count: FAKE_MAIN_PANES, or 1
#   pane list --workspace <ws>   one pane, <ws>:p1
#   pane process-info --pane <p> the shell alone, or with a program in front
#                                of it when FAKE_MAIN_BUSY=1
#   workspace close <ws>     closes it
#   pane read <pane>         FAKE_SCREEN when set
#   status --json            FAKE_STATUS, or a healthy herdr 0.9.5
#   integration status       FAKE_INTEG, or "claude: current (v11)"
#   agent list               FAKE_AGENT_LIST, or no agents
# FAKE_SLEEP=<s> makes worktree create take that long.

set -euo pipefail

D="${FAKE_DIR:?FAKE_DIR not set}"
mkdir -p "$D/ws" "$D/main"
printf '%s\n' "$*" >>"$D/calls"
# FAKE_SILENT=1: fail with status 3 and nothing on stderr, as a killed herdr does.
[[ "${FAKE_SILENT:-}" != 1 ]] || exit 3

fail() { printf '{"error":{"code":"%s","message":"%s"}}\n' "$1" "$2" >&2; exit 1; }

# A label such as "a · mcv" as a file name.
wsid() { printf 'ws-%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-')"; }
open_main() { # <repo path>
  local p
  p="$(cd "$1" && pwd -P)"
  [[ -f "$D/main/ws-main-${p##*/}" ]] || printf '%s\n' "$p" >"$D/main/ws-main-${p##*/}"
}
[[ -z "${FAKE_MAIN_OPEN:-}" ]] || open_main "$FAKE_MAIN_OPEN"

case "${1:-} ${2:-}" in
  "worktree create")
    shift 2
    cwd="" branch="" base="HEAD" label=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'begin %s\n' "$label" >>"$D/order"
    [[ -z "${FAKE_SLEEP:-}" ]] || sleep "$FAKE_SLEEP"
    if [[ "${FAKE_FAIL:-}" == create ]]; then
      git -C "$cwd" branch "$branch" "$base" >/dev/null 2>&1
      printf 'end %s\n' "$label" >>"$D/order"
      fail git_failed "could not lock config file"
    fi
    id="$(wsid "$label")"
    wt="$D/wt/${id#ws-}"
    # herdr 0.9.5 checks out a local branch that already exists as it is
    # (measured with no --base, the only way spawn asks for one).
    if git -C "$cwd" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$cwd" worktree add -q "$wt" "$branch" >/dev/null 2>&1
    else
      git -C "$cwd" worktree add -q -b "$branch" "$wt" "$base" >/dev/null 2>&1
    fi
    printf '%s\t%s\t%s\n' "$cwd" "$wt" "$label" >"$D/ws/$id"
    open_main "$cwd"
    printf 'end %s\n' "$label" >>"$D/order"
    case "${FAKE_FAIL:-}" in
      partial) printf '{"result":{"workspace":{"workspace_id":"%s"}}}\n' "$id"; exit 0 ;;
      garbage) echo "Segmentation fault"; exit 0 ;;
    esac
    jq -cn --arg ws "$id" --arg wt "$wt" '{result: {
      root_pane: {pane_id: ($ws + ":p1")},
      workspace: {workspace_id: $ws, worktree: {is_linked_worktree: true}},
      worktree: {path: $wt}}}'
    ;;
  "workspace list")
    {
      for f in "$D"/main/ws-main-*; do
        [[ -f "$f" ]] || continue
        jq -cn --arg ws "${f##*/}" --arg p "$(cat "$f")" \
          '{workspace_id: $ws, label: ($p | split("/") | last),
            worktree: {is_linked_worktree: false, checkout_path: $p, repo_root: $p}}'
      done
      for f in "$D"/ws/ws-*; do
        [[ -f "$f" ]] || continue
        IFS=$'\t' read -r repo wt l <"$f"
        jq -cn --arg ws "${f##*/}" --arg l "$l" --arg wt "$wt" --arg r "$(cd "$repo" 2>/dev/null && pwd -P)" \
          '{workspace_id: $ws, label: $l,
            worktree: {is_linked_worktree: true, checkout_path: $wt, repo_root: $r}}'
      done
    } | jq -cs '{result: {workspaces: .}}'
    ;;
  "workspace get")
    [[ -f "$D/main/$3" || -f "$D/ws/$3" ]] || fail workspace_not_found "workspace $3 not found"
    printf '{"result":{"workspace":{"workspace_id":"%s","pane_count":%s}}}\n' "$3" "${FAKE_MAIN_PANES:-1}"
    ;;
  "workspace close")
    [[ -f "$D/main/$3" || -f "$D/ws/$3" ]] || fail workspace_not_found "workspace $3 not found"
    rm -f "$D/main/$3" "$D/ws/$3"
    echo '{"result":{}}'
    ;;
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"%s:p1"}]}}\n' "$4"
    ;;
  "pane process-info")
    if [[ "${FAKE_MAIN_BUSY:-}" == 1 ]]; then
      echo '{"result":{"process_info":{"foreground_process_group_id":200,"shell_pid":100}}}'
    else
      echo '{"result":{"process_info":{"foreground_process_group_id":100,"shell_pid":100}}}'
    fi
    ;;
  "worktree remove")
    [[ "${FAKE_FAIL_REMOVE:-}" != 1 ]] || fail internal "worktree remove failed"
    ws="$4"
    [[ -f "$D/ws/$ws" ]] || fail workspace_not_found "workspace $ws not found"
    IFS=$'\t' read -r repo wt _ <"$D/ws/$ws"
    # When git fails, herdr answers with git's own words and keeps the
    # workspace (measured with herdr 0.9.5: "failed to delete ... Directory
    # not empty", then "is not a working tree" on the next try).
    if ! err="$(git -C "$repo" worktree remove --force "$wt" 2>&1)"; then
      fail worktree_remove_failed "$(printf '%s' "$err" | head -1)"
    fi
    rm -f "$D/ws/$ws"
    echo '{"result":{}}'
    ;;
  "agent start")
    [[ "${FAKE_FAIL:-}" != start ]] || fail agent_not_ready "claude did not start"
    printf '%s\n' "$3" >>"$D/agents"
    # Claude with the mcv plugin loaded runs its SessionStart hook, with the
    # env that --settings carries.
    if [[ "${FAKE_NOHOOKS:-}" != 1 ]]; then
      agent="$3"
      settings=""
      while [[ $# -gt 0 ]]; do
        [[ "$1" == --settings ]] && { settings="$2"; break; }
        shift
      done
      src="${BASH_SOURCE[0]}"
      [[ ! -L "$src" ]] || src="$(readlink "$src")"
      # with the hook input Claude gives (measured with Claude Code 2.1).
      MCV_TASK="$(jq -r .env.MCV_TASK <<<"$settings")" MCV_HOME="$(jq -r .env.MCV_HOME <<<"$settings")" \
        "$(dirname "$src")/../../bin/mcv-status" --contract >/dev/null \
        <<<"{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"transcript_path\":\"$D/transcripts/$agent.jsonl\"}"
    fi
    echo '{"result":{}}'
    ;;
  "agent get")
    grep -qxF "$3" "$D/agents" 2>/dev/null || fail agent_not_found "agent $3 not found"
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FAKE_AGENT_STATE:-idle}"
    ;;
  "status --json")
    if [[ -n "${FAKE_STATUS:-}" ]]; then printf '%s\n' "$FAKE_STATUS"; else
      echo '{"client":{"version":"0.9.5"},"server":{"status":"running","version":"0.9.5","endpoint_compatible":true}}'
    fi
    ;;
  "integration status")
    if [[ -n "${FAKE_INTEG:-}" ]]; then printf '%s\n' "$FAKE_INTEG"; else echo 'claude: current (v11)'; fi
    ;;
  "agent list")
    if [[ -n "${FAKE_AGENT_LIST:-}" ]]; then printf '%s\n' "$FAKE_AGENT_LIST"; else echo '{"result":{"agents":[]}}'; fi
    ;;
  "pane read")
    if [[ -n "${FAKE_SCREEN:-}" ]]; then printf '%s\n' "$FAKE_SCREEN"; else echo "screen of $3"; fi
    ;;
  "agent prompt")
    [[ "${FAKE_FAIL:-}" != notready ]] || fail agent_not_ready "$3 is not an active named agent"
    [[ "${FAKE_FAIL:-}" != notrunning ]] || fail agent_not_running "$3 is not running"
    echo '{"result":{"agent":{"agent_status":"working"}}}'
    ;;
  *)
    fail unsupported "fake-herdr does not support: $*"
    ;;
esac
