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
| `bin/mcv-herdr.sh` | Every herdr call: `doctor`, `spawn`, `prompt`, `read`, `agents`, `remove`. Owns task state; journals each spawn, prompt and remove. | herdr, git |
| `bin/mcv-status` | A worker's reports, the coordinator's answers and journal notes, the text the hooks give a worker, and the git guard. | the status log, the journal |
| `bin/mcv-watch` | One event stream for the Monitor tool: new log lines and worker state changes worth a coordinator turn. | status logs; `mcv-herdr.sh agents` |
| `hooks/hooks.json` | SessionStart gives a worker its rules; PreToolUse refuses AskUserQuestion, and on Bash refuses git commands past the worker's branch. Opt-in. | `mcv-status` |

herdr does the process work (worktrees, panes, starting Claude, delivering prompts, reporting
state); mcv keeps the bookkeeping (which task each worker has, its questions and answers).

## Lifecycle of a task

1. **Dispatch.** The coordinator picks the repo, task id and branch, writes the task text (facts the
   worker cannot find itself), and waits for the user's yes.
2. **Spawn** (`mcv-herdr.sh spawn`), in this order:
   1. Validate names; claim the worker name (`$MCV_HOME/.claims/<name>`), so no second spawn of it
      or of a name that joins the same can run; clear a task folder that has no meta.
   2. Refuse an existing branch, locally or on a remote, ignoring case, and `main`/`master`/`develop`.
      With `--existing`, the reverse: the branch must be on the remote (checked after the fetch).
   3. Lock the repository (`$MCV_HOME/.locks/<repo key>`), fetch, resolve the base (`--base`, else
      the default branch of `origin` or of the only remote, else HEAD when there is no remote).
      With `--existing` the base is `<remote>/<branch>`, refused when that is the remote's default
      branch, when another task's meta names the branch in this repository, or when a local
      branch of that name is checked out or holds commits the remote lacks; a local branch behind
      the remote is moved up to it (`update-ref` with the old value) and handed to herdr without
      `--base`, since herdr checks out an existing local branch as it is. A failed spawn deletes
      the local branch only if it made it.
   4. `herdr worktree create`, labelled `⧉ <id> · <project>`; if herdr opened a workspace for the
      repository's main checkout with it (none was open before), record its id in
      `.repo-workspaces/<repo key>`. Write meta at once, with the base commit and a `starting`
      marker.
   5. Check the worktree is not the main checkout; clear the branch's upstream (with `--existing`:
      check the worktree is on the branch at the remote's tip and set the remote branch as its
      upstream); release the lock. Meta records `existing`, and the worker's rules then say the
      branch is already on the remote and not to open a second request.
   6. Refuse a context that holds the worktree; copy `.worktreeinclude` files; rewrite meta with
      the count.
   7. `herdr agent start` with `--add-dir <context>` (if any) and `--settings` carrying `MCV_TASK`,
      `MCV_HOME`, and for a context `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` and a deny rule
      for edits there. If it fails, the error ends with the pane's last four lines (`pane read`),
      since herdr types the command at the shell prompt and only reports a timeout when the shell
      took it. Remove `starting`. Claude arguments after `--` follow; spawn refused
      `--add-dir` and `--settings` among them (and `--base`/`--context`) before step 1, since
      either would undo the deny rule or `MCV_TASK`.

   A failure, or INT/TERM/HUP, before step 7 undoes the worktree, branch and task. From step 7 on
   the task stays, for `remove`.
3. **Work.** The worker's SessionStart hook prints its rules, leaves `rules-loaded` in the task
   folder and adds the session's transcript path (from the hook's input) to `transcripts`;
   `prompt` refuses a worker without `rules-loaded`, whose Claude did not load the plugin. The
   worker reports through `mcv-status`; a `needs-decision` prints a question id and the worker
   ends its turn. Its PreToolUse hook on Bash refuses a git command that reaches past its branch
   (Git guard, below).
4. **Watch.** `mcv-watch` prints the event; the coordinator relays the question to the user as
   `<id> #<n>`, reads the worker's screen, and sends the answer with
   `prompt --no-wait --answers q<n>`. `prompt` records what became of it, through `mcv-status`:
   `answered` once the text is sent, `pending` when the worker is busy, and the watcher prints a
   pending answer back as `DELIVER` when the worker stops. An order that answers no question
   takes the same path with `--order`: a busy worker gets nothing and the order is queued under
   a new order id (`o1`, ...), picked under the log's lock. Sending and recording were two
   commands until 0.2.10; in real runs they were joined with `;` in 13 of 34 calls, and one
   refused send left a question recorded as answered that could no longer be queued.
5. **Remove** (`mcv-herdr.sh remove`), when the user agrees: refuse a dirty worktree, remove it
   through herdr (or git, if the workspace is already gone), copy the task's `meta`, `status.log`
   and `transcripts` to `<project>/history/<id>-<UTC time>/` (if that fails, the task state
   stays), delete the task state, then the project's `tasks` folder and herdr's per-repository
   folder if they are left empty. The branch stays, unless it is still at the base commit in meta,
   has no upstream and no remote-tracking ref of that name: then it held no work and is deleted
   (a task from before 0.2.1 has no base commit, so its branch stays). Last, when no worktree of
   the repository is open any more, close the main-checkout workspace recorded in
   `.repo-workspaces/<repo key>`, if it still has one pane whose shell has nothing in front of it.

`spawn`, `prompt` and `remove` each add a line to `<project>/journal.log`, done or refused, once
the command has a sound task name (only `spawn` creates the project folder for it).

## State

Everything lives under `$MCV_HOME` (default `~/.claude/mcv`), outside every repository.

```
$MCV_HOME/
  .claims/<project>-<id>/pid          held during one spawn of that worker name
  .locks/<repo key>/pid               held while one spawn fetches and creates a worktree there
  .repo-workspaces/<repo key>         id of the main-checkout workspace herdr opened for a spawn
  <project>/watch.lock/pid            held by the one mcv-watch of that project
  <project>/watch.lock/owner          pid of the Claude process that watcher runs under, or empty
  <lock>.takeover/                    next to any lock below, held while one process takes it over
  <project>/tasks/<id>/
    meta                              JSON, written whole and renamed into place
    starting                          present until Claude has started
    rules-loaded                      left by the worker's SessionStart hook
    transcripts                       the worker's Claude transcript paths, one per session
    status.log                        one event per line
    status.log.lock/pid               held during one write to the log
  <project>/journal.log               one line per helper call and coordinator note; kept
  <project>/history/<id>-<time>/      meta, status.log, transcripts, copied by remove; kept
```

**journal.log** line: `<UTC time>\t<source>\t<project>/<id> or ->\t<text>`, with source `spawn`,
`prompt` or `remove` (text `ok: <what>` or `error: <the refusal>`; prompt logs the text's length,
not the text) or `note` (the coordinator's, through `mcv-status --journal`). Lines are short and
appended in one write each, so writers take no lock. Nothing deletes the journal or history.

**meta** fields: `task`, `agent`, `workspace_id`, `pane_id`, `worktree`, `repo`, `branch`, `base`,
`base_sha` (the commit the branch started at), `context` (empty when none), `copied` (number of
files from `.worktreeinclude`), `created` (UTC).

**status.log** line: `<UTC time>\t<kind>\t<question id or ->\t<text>`, with kind one of
`needs-decision`, `blocked`, `done`, `failed`, `note`, `waiting` (the worker's), `pending`,
`answered`, `amended` (the coordinator's). Text has tabs, newlines and other control characters
removed. Question ids are `q1`, `q2`, ... per task, and order ids `o1`, `o2`, ... A question is
open until it has an `answered` line; a `pending` line holds an answer, or an order, the
coordinator could not send yet (an order's `answered` line records that it was sent); an `amended` line, only
after `answered`, holds a correction sent later, so the log says what the worker was last told.

**Locks** are folders created with `mkdir` (atomic) holding `<pid> <epoch seconds>`. A lock whose
pid has exited without releasing it is taken over, but only when it is unchanged since read and at
least 2 seconds old, so a lock another process has just taken is never deleted. A claim or repo lock
with no pid (its holder was killed between making it and writing the pid) is taken over once it is
a minute old. The watch lock counts as held while its pid is an mcv-watch. It also names its
owner, the nearest ancestor process whose command is `claude` (measured: a Monitor command runs in
a shell that is that process's child). A new watcher with the same owner stops the holder with
TERM, on which it exits 0, and takes the lock: `/clear` starts a new conversation in the same
Claude process and leaves the old conversation's watcher running for up to 30 minutes (measured in
the fourth real run, three times; one task waited 22 minutes for the lock). With another owner, or
none on either side, the new watcher is refused.

Every lock is taken over only under a second lock, `<lock>.takeover`, whose holder checks the
lock again, deletes it, makes its own and writes its pid before letting go. Without it, two
processes that both found a lock stale could each delete it, the second deleting the first one's
new lock, and both go ahead: measured as repeated question ids in most rounds of 12 writers on a
stale log lock, and overlapping worktree creations in 2 of 5 rounds of 8 spawns. A takeover lock
left by a killed process is cleared when its pid has exited and it is 2 seconds old, or it has no
pid and is a minute old (5 seconds for the watcher's).

**Watcher state** (in `$MCV_WATCH_STATE`, by default `$MCV_HOME/<project>/watch-state`), one line
per task in `<state>/<project>/<id>`: `<pane> <last state> <change counter> <log lines read> <last
kind> <gone> <owe> <delivered> <waiting since>`, where owe marks a pending answer read while herdr
was down, delivered is the log line up to which pending answers were already delivered, so each
pending line is delivered once, and waiting since is the time of the stop a `waiting` line
announced (0 when none). The state outlives the watcher: the Monitor tool ends it after 30
minutes, and `mcv-watch <project> --resume` goes on from it; started without `--resume`, the
watcher clears it and starts afresh. The coordinator resumes at once while a worker is busy
(working, at a dialog, or in a wait it announced; a question waiting for the user is not busy), and
otherwise just before its next `spawn` or `prompt` (measured on herdr 0.9.5: it did so, and the
only event was the new `DONE`), so an idle project costs no wake-ups. It starts one only after
the last one's expiry or failure notice; the lock refuses a second watcher for the same project
(measured: one started 24 minutes into the last one's 30 exited at once, with no duplicate events).
The pane identifies the worker: a task removed and spawned again gets a new pane and a fresh start.

## Watcher events

One per line, `⧉ <id> · <EVENT>[ <qid>] · <text>`, so the coordinator and the user can tell mcv's
lines from the rest of a session. `MCV_WATCH_RAW=1` gives the same events tab-separated, as the
tests read them; the raw kind is in brackets:

```
⧉ <id> · QUESTION <qid> · <text>   (needs-decision) a worker's question
⧉ <id> · BLOCKED · <text>          (blocked) the worker reports it cannot go on
⧉ <id> · DONE · <text>             (done)
⧉ <id> · FAILED · <text>           (failed)
⧉ <id> · WAITING · ...             (state blocked) the worker stopped at a dialog
⧉ <id> · RESUMED · ...             (state working) it left that dialog: answered in its pane
⧉ <id> · STOPPED · ...             (state done) a turn ended with no report line since the last event,
                                   or (state done, wait) a wait it announced outlasted the limit
⧉ <id> · DELIVER <qid> · <answer>  (deliver) a pending answer or order, now that the worker has stopped
⧉ <id> · GONE · ...                (gone) the worker no longer runs Claude
```

`DELIVER` goes out when the worker stops (reaches done or idle from another state, or ends another
turn) while an answer is pending, or at once when the answer is recorded after it stopped; it
replaces the `STOPPED` of that stop. `RESUMED` is the one change to working that is printed: from
blocked. Without it a coordinator last told "blocked" kept asking the user to approve a dialog
they had already answered in the pane (seen in the first real run). `STOPPED` is a turn end, not
the end of the task. A worker that waits on a sub-agent or a build has to end its turn: Claude
Code refuses a long foreground `sleep` and says to wait in the background (measured). It says so
first with a `waiting` line; the stop that follows prints nothing, unless the worker is still
stopped `MCV_WATCH_WAIT_LIMIT` seconds later (default 1800), which prints `STOPPED` once.
A worker that owes nothing gets no `STOPPED` and no timed wait: its last report (notes and waits
aside) is a question, a block, done or failed, and `journal.log` has no `prompt ... ok:` line
for it after that report's time. In the fourth real run all three `STOPPED` were of that kind: a
note sent right after a question, and twice Claude compacting the context of a worker that had
been idle for 55 minutes. A prompt the user types into the pane is not journaled, so a silent
stop after one is not reported.
An event carries what the coordinator needs to act on it, because each tool call it makes
afterwards is another call at its full context. Measured in the fourth real run: every one of 28
`WAITING` events was followed by a `read` of the dialog, and 15 of 21 questions took a second
call, 11 of them to read `status.log`, because the Monitor tool cuts a line at about 500
characters (400 arrived whole, 600 was cut) and 15 of the 22 questions were longer than 400. It
cuts a notification at about 3000 (seven lines of 420 arrived, the eighth was cut). So a text
longer than 400 characters is printed over several lines, each later one marked `  …`, cut by
jq at characters, not bytes; past 2600 it stops and the last line points to `status.log`. And
`WAITING` is followed by what the dialog shows, each line marked `  | `: the worker's screen
(`mcv-herdr.sh read`, 80 lines) below its last full-width rule, without the dashed rules, the
answer pointer and the key hints; nothing when there is no such rule. The notification drops the
leading spaces, so the marks arrive as `…` and `|`. A `DONE` needs nothing more: 36 of 56 were
handled in one call.

Two limits of that design were measured afterwards, on the screens of that run and with a real
Monitor. A dialog cut to its first 10 lines lost the bottom, which is the part that matters:
of 15 real dialogs 14 lost an answer line and one the question itself. So a dialog longer than
12 lines is shown as its first 4 lines and its last 8, with a line between saying how many are
left out, each line cut at 200 characters, which keeps a dialog inside one notification. And
the Monitor tool joins lines that come within 200 ms into one notification before it cuts at
about 3000 characters: of two 1500-character questions asked in one poll, the end of the second
was lost, with nothing to say so. So the watcher counts what it has printed since the last
poll, and an event that would take that past 2800 characters waits 0.4 seconds first; the two
questions then arrived as two notifications, both whole.

`note` and `waiting` lines are never printed: each printed line costs a coordinator turn at its
full context, and in the second real run notes, restarts and stops during waits were about a
fifth of the coordinator's cost. On its first poll without `--resume` the watcher prints the
questions still without an answered or pending line, the deliveries owed, and nothing else from
the past; with `--resume` it prints only what is new.

## Git guard

`mcv-status --guard-git`, the worker's PreToolUse hook on Bash, gets the command and its folder
from the hook's input (`tool_input.command`, `cwd`) and the worker's branch from meta. It removes
redirections (`2>&1`, `>file`, `2> file`, `&>file`, `<file`, here-documents and here-strings; a
number counts as a file descriptor only as a word of its own), then splits the
command at `;`, `&`, `|`, `(`, `)`, `` ` ``, `{`, `}` and newlines, drops quotes, and looks at each
piece that starts with `git` (after `VAR=value`, `env`, `command`, `exec`, `sudo`, `nohup`;
following `-C`). It refuses, with a reason that names the worker's branch and `needs-decision`:

- `push` with `--force`, `-f` (also inside `-uf`), `--force-if-includes` or a `+` refspec;
  `--force-with-lease` passes, but only to the worker's branch like any push;
- `push` with `--all`, `--branches`, `--mirror`, `--tags` or `--prune`;
- `push` to any destination but the worker's branch (`refs/heads/` stripped; a tag or other ref is
  refused), deletes included; with no refspec, or `HEAD`, the branch checked out in that folder
  must be the worker's;
- `branch` deleting a branch but the worker's (remote-tracking `-r` passes), renaming any, `-C`,
  or `-f` on another branch; `tag -d` and `tag -f`; `update-ref` on another branch or a tag;
  `checkout -B` and `switch -C` on another branch.

It works from the command's text: a script, an alias or a variable hides a command from it, and a
quoted message that holds such a command is refused too. It guards against mistakes in an
unattended worker; a server-side protected branch is the guarantee. Checked with a real Claude
worker (Claude Code 2.1): `git tag -d` was refused before it ran, with the reason shown to the
worker.

## Invariants

- A worker never runs in the user's checkout: spawn checks the worktree's git dir differs from the
  common one.
- A worker's branch is new, exists nowhere else in any letter case, is never a shared branch, and
  has no upstream.
- Hooks do nothing outside a worker.
- A worker's git command that pushes to another branch, force-pushes, or deletes or moves another
  branch or a tag is refused before it runs, as far as its text shows it (Git guard).
- No work is sent to a worker that did not get its rules: `prompt` needs `rules-loaded`.
- An answer or order the user gave is never lost to a busy worker: it waits as `pending` until
  delivered.
- A question is recorded as answered by a send only when the text went in: `prompt --answers`
  checks the id first, sends, then records, and records nothing when the send fails.
- `remove` ends in the same place however many times it is run: each step of taking the worktree
  and its workspace away (`drop_worktree`, shared with the clearing of a killed spawn) looks at
  what is there first. Seen twice in real runs before that: a dev server left in the worktree
  kept writing an ignored folder, git dropped the worktree from its list but could not delete
  the folder, herdr kept the workspace, and every later `remove` stopped at the folder ("git
  cannot read") or at herdr ("is not a working tree"). A folder left at the path of a worktree
  git no longer lists is deleted; if it comes back within a second, `remove` says something
  still writes there and stops. It does not look for the process or kill it.
- A worker is refused when it records an answer (`mcv-status --task` with `MCV_TASK` set), and its
  rules forbid it; see Known limits for what that does not stop.
- Errors are one line; no command leaves a half-made task that `remove` cannot clean up. A spawn
  killed outright (SIGKILL) between asking herdr for the worktree and writing meta used to: herdr
  finished the worktree and the branch with no task to name them, `remove` said "no task", and
  spawn refused the branch as taken (measured at seven moments of a spawn; the four after herdr
  had begun left that). Before the call spawn now writes `tasks/<id>/spawning` (repository,
  branch, workspace label, whether the branch is its own, the commit it starts at) and deletes
  it once meta is written. `remove <project>/<id>` on a folder with that file and no meta, and a
  spawn of the same task again, clear what it names under the task's claim: the workspace by its
  label, the worktree by its branch, and the branch if it is the spawn's own and still at its
  starting commit. A leftover worktree with changes is refused.

## herdr behaviour relied on

Measured against herdr 0.9.5 (protocol 22) on macOS, 2026-11-06 and 2026-11-07.

| Behaviour | Notes |
|---|---|
| `worktree create --cwd --branch --base --label --no-focus` | Returns workspace id, root pane id, worktree path. Reuses an existing branch without complaint, hence spawn's checks. Gives a branch made from a remote-tracking ref that ref as upstream. Measured 2026-11-11: an existing local branch is checked out as it is; `--branch X --base origin/X` with no local X checks out the remote branch with upstream `origin/X`; `--branch X` with no `--base` and no local X makes a new X from HEAD without a word, even when `origin/X` exists, so `spawn --existing` always passes `--base` then. |
| `agent start <name> --kind claude --pane <id> -- <claude args>` | In a folder Claude has not trusted, stops at the trust dialog (default answer "No, exit") and fails with `agent_not_ready`; once the user picks "Yes", the agent takes prompts. Claude (2.1.319) records that trust under the repository's main checkout, so every worktree of a trusted repository starts without the dialog; a trusted parent folder does not count. Behind the dialog herdr reports the agent `idle` or `blocked` (both seen), and the SessionStart hook has not run. Without the dialog, `rules-loaded` is already written when `agent start` returns. |
| `agent prompt <name> <text> --wait [--until ...]` | Text starting with `-` is taken as text. Refuses an agent that is not idle or done. |
| Claude exiting in its pane | herdr either drops the agent (`agent_not_found`) or lists it as done but refuses prompts (`agent_not_ready`, or `agent_not_running` as seen after `/exit`). `pane read` still shows the screen. |
| `worktree remove --workspace <id>` | Removes the worktree and closes the workspace. After the user closes the workspace, it fails with `workspace_not_found`, and git removes the worktree instead. When git fails it answers `worktree_remove_failed` with git's own words and keeps the workspace (seen 2026-11-14 and 11-15: "failed to delete ... Directory not empty", then "is not a working tree" once the folder was gone); `workspace close <id>` then closes that workspace (seen 2026-11-15). |
| Repository workspaces (2026-11-08, 2026-11-09) | Every worktree workspace sits under a workspace for its repository's main checkout. When none is open, one `worktree create` opens both; `worktree remove` closes only the worktree's. Closing the main-checkout workspace closes its worktree workspaces in the same instant. `workspace list` gives each `worktree.is_linked_worktree`, `checkout_path` and `repo_root`; `pane process-info` gives `shell_pid` and `foreground_process_group_id`, equal when the shell is idle. A label may hold spaces and `/`. |
| Shell in a new pane | `agent start` types the claude command at the pane's shell prompt. Seen: oh-my-zsh's "update? [Y/n]" prompt took the first `c`, the shell ran `laude`, and `agent start` failed with only `timeout: timed out waiting for agent startup`. |
| `status --json`, `integration status` | `doctor` requires herdr >= 0.9.5 and the Claude integration `current`; updating herdr does not refresh the integration. It also prints mcv's own version, read from `.claude-plugin/plugin.json` beside its copy, which the coordinator shows when it opens: a session keeps the helpers it started with (measured: one ran 0.2.0's after 0.2.2 was installed). |
| `--settings '{"env": ...}'` | Reaches both the hooks and the Bash tool of the worker. |

Not yet observed: which signal the Monitor tool stops `mcv-watch` with; whether workers survive
with every herdr window closed.

## Known limits

- `spawn --context` denies Claude's file-editing tools in the context folder; a shell command
  could still write there, as in any session.
- Task state is not a security boundary. A worker runs as the user: one that unsets `MCV_TASK`
  can record an answer to its own question, and one that sets it can write into another task's
  log. mcv refuses the plain cases and the worker's rules forbid the rest.
- The git guard reads command text; a script, an alias or a variable gets past it. Beyond git,
  a worker in auto mode is limited only by Claude Code's own permission checks.
- herdr types the worker's `claude --settings ...` command at the pane's shell prompt, so it is in
  that shell's history. It holds the task name and paths only.
- herdr shows each worker under the workspace it takes as its repository's main checkout, not
  under the coordinator's; mcv cannot choose (measured: `worktree create --workspace` names the
  repository through an open workspace, in place of `--cwd`, and does not pick a parent). When the
  user already had that workspace open, workers appear under it, and closing it closes them.
- `remove` closes a main-checkout workspace only when a spawn made herdr open it and it is still
  idle with one pane; one the user has started using stays open, for a later remove.
- Anything a new pane's shell asks before its prompt (an update check, a plugin question) breaks
  `agent start`. mcv cannot answer it; the error shows it so the user can turn it off.
- SIGKILL to `spawn` while herdr creates the worktree can leave that worktree behind.

## Next

- A coordinator over several projects at once: [ADR 0005](adr/0005-hub-coordinator.md). Its
  per-repository config is built; the hub itself is still proposed.
