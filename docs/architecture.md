# mcv architecture

How mcv is built: its parts, what they store, the rules each one keeps, and the herdr behaviour it
relies on. Why it is built this way is in the decision records, [docs/adr/](adr/).

## Terms

- **coordinator**: the Claude Code session the user talks to. It follows the `/mcv` skill.
- **worker**: another Claude Code session the coordinator starts, in its own git worktree.
- **project**: a short name the user picks to group tasks; it names the state folder and prefixes
  every worker name.
- **repo**: a git repository a worker can be started in, listed in the project config.
- **task**: one piece of work given to one worker, named `<project>/<id>`. Its herdr agent is
  named `<project>-<id>`.

## Parts

```
 user ⇄ coordinator (Claude Code, /mcv skill)
            │  Bash: bin/mcv-herdr.sh ──────────► herdr ──► worker panes (Claude Code)
            │  Monitor: bin/mcv-watch ◄── reads ── status logs + herdr agent states
            │                                        ▲
            │                                        │ bin/mcv-status (run by each worker)
            └─ records answers: bin/mcv-status --task
```

| Part | Job | Talks to |
|---|---|---|
| `skills/mcv/SKILL.md` | The coordinator's procedure: config, dispatch, relaying questions, sending answers, cleanup. | the user; the three scripts |
| `bin/mcv-herdr.sh` | Every herdr call: `doctor`, `spawn`, `prompt`, `read`, `agents`, `remove`. Owns task state. | herdr, git |
| `bin/mcv-status` | A worker's reports, the coordinator's answers, and the text the hooks give a worker. | the status log |
| `bin/mcv-watch` | One event stream for the Monitor tool: new log lines and worker state changes worth a coordinator turn. | status logs; `mcv-herdr.sh agents` |
| `hooks/hooks.json` | SessionStart gives a worker its rules; PreToolUse refuses AskUserQuestion. Opt-in. | `mcv-status` |

herdr does the process work (worktrees, panes, starting Claude, delivering prompts, reporting
state); mcv keeps the bookkeeping (which task each worker has, its questions and answers).

## Lifecycle of a task

1. **Dispatch.** The coordinator picks the repo, task id and branch, writes the task text (facts the
   worker cannot find itself), and waits for the user's yes.
2. **Spawn** (`mcv-herdr.sh spawn`), in this order:
   1. Validate names; claim the worker name (`$MCV_HOME/.claims/<name>`), so no second spawn of it
      or of a name that joins the same can run; clear a task folder that has no meta.
   2. Refuse an existing branch, locally or on a remote, ignoring case, and `main`/`master`/`develop`.
   3. Lock the repository (`$MCV_HOME/.locks/<repo key>`), fetch, resolve the base (`--base`, else
      the default branch of `origin` or of the only remote, else HEAD when there is no remote).
   4. `herdr worktree create`; write meta at once, with a `starting` marker.
   5. Check the worktree is not the main checkout; clear the branch's upstream; release the lock.
   6. Refuse a context that holds the worktree; copy `.worktreeinclude` files; rewrite meta with
      the count.
   7. `herdr agent start` with `--add-dir <context>` (if any) and `--settings` carrying `MCV_TASK`,
      `MCV_HOME`, and for a context `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` and a deny rule
      for edits there. Remove `starting`. Claude arguments after `--` follow; spawn refused
      `--add-dir` and `--settings` among them (and `--base`/`--context`) before step 1, since
      either would undo the deny rule or `MCV_TASK`.

   A failure, or INT/TERM/HUP, before step 7 undoes the worktree, branch and task. From step 7 on
   the task stays, for `remove`.
3. **Work.** The worker's SessionStart hook prints its rules and leaves `rules-loaded` in the task
   folder; `prompt` refuses a worker without it, whose Claude did not load the plugin. The worker
   reports through `mcv-status`; a `needs-decision` prints a question id and the worker ends its
   turn.
4. **Watch.** `mcv-watch` prints the event; the coordinator relays the question to the user as
   `<id> #<n>`, reads the worker's screen, sends the answer with `prompt --no-wait`, and records it
   with `mcv-status --task ... answered`. If the worker is still busy, the coordinator records the
   answer as `pending` instead, and the watcher prints it back as `deliver` when the worker stops.
5. **Remove** (`mcv-herdr.sh remove`), when the user agrees: refuse a dirty worktree, remove it
   through herdr (or git, if the workspace is already gone), delete the task state, then the
   project's state folder and herdr's per-repository folder if they are left empty. The branch
   stays.

## State

Everything lives under `$MCV_HOME` (default `~/.claude/mcv`), outside every repository.

```
$MCV_HOME/
  .claims/<project>-<id>/pid          held during one spawn of that worker name
  .locks/<repo key>/pid               held while one spawn fetches and creates a worktree there
  <project>/watch.lock/pid            held by the one mcv-watch of that project
  <project>/tasks/<id>/
    meta                              JSON, written whole and renamed into place
    starting                          present until Claude has started
    rules-loaded                      left by the worker's SessionStart hook
    status.log                        one event per line
    status.log.lock/pid               held during one write to the log
```

**meta** fields: `task`, `agent`, `workspace_id`, `pane_id`, `worktree`, `repo`, `branch`, `base`,
`context` (empty when none), `copied` (number of files from `.worktreeinclude`), `created` (UTC).

**status.log** line: `<UTC time>\t<kind>\t<question id or ->\t<text>`, with kind one of
`needs-decision`, `blocked`, `done`, `failed`, `note` (the worker's), `pending`, `answered` (the
coordinator's). Text has tabs, newlines and other control characters removed. Question ids are
`q1`, `q2`, ... per task. A question is open until it has an `answered` line; a `pending` line holds
an answer the coordinator could not send yet.

**Locks** are folders created with `mkdir` (atomic) holding `<pid> <epoch seconds>`. A lock whose
pid has exited without releasing it is taken over, but only when it is unchanged since read and at
least 2 seconds old, so a lock another process has just taken is never deleted. A claim or repo lock
with no pid (its holder was killed between making it and writing the pid) is taken over once it is
a minute old. The watch lock holds only a pid and counts as held while that pid is an mcv-watch.

**Watcher state** (in `$MCV_WATCH_STATE`, a temporary folder by default), one line per task in
`<state>/<project>/<id>`: `<pane> <last state> <change counter> <log lines read> <last kind> <gone>
<owe> <delivered>`, where owe marks a pending answer read while herdr was down, and delivered is
the log line up to which pending answers were already delivered, so each pending line is delivered
once.
The pane identifies the worker: a task removed and spawned again gets a new pane and a fresh start.

## Watcher events

Tab-separated, one per line:

```
<time>  <project>/<id>  <kind>   <qid|->  <text>   a new worker line in the status log
<time>  <project>/<id>  deliver  <qid>    <text>   a pending answer, now that the worker has stopped
<time>  <project>/<id>  state    blocked           the worker stopped at a dialog
<time>  <project>/<id>  state    done              a turn ended with no report line since the last event
<time>  <project>/<id>  gone     -                 the worker no longer runs Claude
```

`deliver` goes out when the worker stops (reaches done or idle from another state, or ends another
turn) while an answer is pending, or at once when the answer is recorded after it stopped; it
replaces the `state done` of that stop. On its first poll the watcher prints the questions still
without an answered or pending line, the deliveries owed, and nothing else from the past.

## Invariants

- A worker never runs in the user's checkout: spawn checks the worktree's git dir differs from the
  common one.
- A worker's branch is new, exists nowhere else in any letter case, is never a shared branch, and
  has no upstream.
- Hooks do nothing outside a worker.
- No work is sent to a worker that did not get its rules: `prompt` needs `rules-loaded`.
- An answer the user gave is never lost to a busy worker: it waits as `pending` until delivered.
- A worker is refused when it records an answer (`mcv-status --task` with `MCV_TASK` set), and its
  rules forbid it; see Known limits for what that does not stop.
- Errors are one line; no command leaves a half-made task that `remove` cannot clean up, except
  SIGKILL in the moment between herdr creating a worktree and meta being written.

## herdr behaviour relied on

Measured against herdr 0.9.5 (protocol 22) on macOS, 2026-11-06 and 2026-11-07.

| Behaviour | Notes |
|---|---|
| `worktree create --cwd --branch --base --label --no-focus` | Returns workspace id, root pane id, worktree path. Reuses an existing branch without complaint, hence spawn's checks. Gives a branch made from a remote-tracking ref that ref as upstream. |
| `agent start <name> --kind claude --pane <id> -- <claude args>` | In a folder Claude has not trusted, stops at the trust dialog (default answer "No, exit") and fails with `agent_not_ready`; once the user picks "Yes", the agent takes prompts. Claude (2.1.319) records that trust under the repository's main checkout, so every worktree of a trusted repository starts without the dialog; a trusted parent folder does not count. Behind the dialog herdr reports the agent `idle` or `blocked` (both seen), and the SessionStart hook has not run. Without the dialog, `rules-loaded` is already written when `agent start` returns. |
| `agent prompt <name> <text> --wait [--until ...]` | Text starting with `-` is taken as text. Refuses an agent that is not idle or done. |
| Claude exiting in its pane | herdr either drops the agent (`agent_not_found`) or lists it as done but refuses prompts (`agent_not_ready`, or `agent_not_running` as seen after `/exit`). `pane read` still shows the screen. |
| `worktree remove --workspace <id>` | Removes the worktree and closes the workspace. After the user closes the workspace, it fails with `workspace_not_found`, and git removes the worktree instead. |
| `status --json`, `integration status` | `doctor` requires herdr >= 0.9.5 and the Claude integration `current`; updating herdr does not refresh the integration. |
| `--settings '{"env": ...}'` | Reaches both the hooks and the Bash tool of the worker. |

Not yet observed: which signal the Monitor tool stops `mcv-watch` with; whether workers survive
with every herdr window closed.

## Known limits

- `spawn --context` denies Claude's file-editing tools in the context folder; a shell command
  could still write there, as in any session.
- Task state is not a security boundary. A worker runs as the user: one that unsets `MCV_TASK`
  can record an answer to its own question, and one that sets it can write into another task's
  log. mcv refuses the plain cases and the worker's rules forbid the rest.
- herdr types the worker's `claude --settings ...` command at the pane's shell prompt, so it is in
  that shell's history. It holds the task name and paths only.
- `remove` leaves open the workspace herdr opened for the repository's main checkout on the first
  spawn there.
- SIGKILL to `spawn` while herdr creates the worktree can leave that worktree behind.
- One concurrency check of the status-log lock failed once on GitHub's shared runner and could not
  be reproduced in 90 local runs; watch for repeated question ids in real use.

## Next

- A coordinator over several projects at once: [ADR 0005](adr/0005-hub-coordinator.md). Its
  per-repository config is built; the hub itself is still proposed.
