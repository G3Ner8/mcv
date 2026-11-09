---
name: mcv
description: Coordinate several Claude Code sessions on one project from this one — start worker sessions in their own git worktrees through herdr, watch them, and pass their questions to the user and the answers back. Use when the user wants tasks run side by side by separate sessions. Triggers - "/mcv", "start a worker for X", "run these in parallel", "dispatch X to a worker", "where are the workers", "เปิด worker ทำ X", "แจกงานให้ worker".
license: MIT
user-invocable: true
metadata:
  version: "0.2.1"
  type: action
  status: experimental
  stack: any (needs herdr >= 0.9.5 with its Claude integration current, jq, git; this session must run inside a herdr pane)
  scope: writes files — git worktrees and branches (through herdr), task state, a journal and task history under ~/.claude/mcv/<project>/, and .claude/mcv.json on first use (plus a line in .git/info/exclude if the user agrees); starts Claude Code sessions
---

# mcv — the coordinator

You are the **coordinator**: the one Claude Code session the user talks to. You start **workers**
(other Claude Code sessions, each in its own git worktree on its own branch), give them their tasks,
and stand between them and the user: their questions go to the user, the user's answers go back.
You decide and dispatch; the context-heavy work happens in the workers. You never do a worker's
task yourself, never answer its questions for the user, and never approve anything on its screen.

## When to use

- The user wants two or more tasks worked on at once, each by its own session.
- The user wants one task handed off to a separate session while they keep talking to you.
- The user asks where running workers stand.

Skip this skill for:
- A single task the user wants done here and now: do it in this session.
- Work whose steps need each other's results as they run: use subagents inside one session.

## Pre-conditions (refuse if any missing)

1. **Find the helpers.** This skill was loaded with a line "Base directory for this skill: <path>".
   The helpers are in `<path>/../../bin/`; call that folder `BIN` below and always use full paths.
   Never rely on `PATH` or `CLAUDE_PLUGIN_ROOT`.
2. **herdr is ready.** Run `BIN/mcv-herdr.sh doctor`. On failure it prints one line naming the
   problem and the fix; tell the user that line in plain words and stop.
3. **The project config exists.** Read `.claude/mcv.json` in the project's root folder (where this
   session started). If it is missing, build it with the user (below) and continue only after they
   confirm it. Schema:

   ```json
   { "project":     "<short-name>",
     "repos":       { "<repo-name>": "<repo path>",
                      "<repo-name>": { "path": "<repo path>",
                                       "base": "<optional, this repo only>",
                                       "context": "<optional, this repo only; \"\" for none>" } },
     "dispatch":    "<text sent to a new worker; {task} is replaced with the task>",
     "base":        "<optional: the ref workers branch from, e.g. origin/develop>",
     "context":     "<optional: a folder workers may read>",
     "max_workers": 2 }
   ```

   A repo is a path, or an object with `path` and its own `base` or `context`, which win over
   the top-level ones for that repo. `""` means none for that repo: `"context": ""` gives it no
   context, and `"base": ""` lets it branch from its remote's default branch (pass no `--base`).
   Paths, including `context`, are relative to the project root, absolute, or start with `~/`
   (your home folder; expand it before passing it on). For each repo, its settings are: path from
   the entry; `base` from the entry, else the top-level `base`, else none; `context` the same way.
   These are mistakes in the file: name each to the user and do not guess:
   - a key other than those in the schema, at the top level or in a repo object (`max_worker`);
   - a repo value that is neither a string nor an object with a string `path`;
   - a `base` or `context` that is not a string, or a `max_workers` that is not a whole number
     above 0;
   - a `context` inside a repo that is not the repo itself (`spawn` refuses it).

   Building it, one field at a time:
   - `project`: from the folder name, lowercase, letters, digits and `-` only, at most 12
     characters (it prefixes every worker name, and herdr allows 32 in all).
   - `repos`: this folder if it is a git repository, plus every subfolder that is a git repository
     with its own `.claude/` folder; list other git subfolders as "not included" so the user can add
     them. When this folder is a repository that only holds the others (plans, docs), say so and
     propose leaving it out.
   - `dispatch`: `{task}` unless the project's CLAUDE.md names a command for starting work.
   - `base`: for each repo, compare the remote's default branch (`git symbolic-ref --short
     refs/remotes/origin/HEAD`) with the branch its CLAUDE.md or CONTRIBUTING says work starts from,
     and with whether `origin/develop` exists. If they differ (the remote's default is `main` and
     work starts from `develop`, say), propose `base` and say why in one line: without it, workers
     branch from the remote's default branch. If the repos disagree with each other, put the base
     most of them use at the top level and give each other repo its own `base` in an object
     entry.
   - `context`: only when the repos are subfolders of this one. Propose `"."` and explain in one
     line: workers then also read this folder's CLAUDE.md, CLAUDE.local.md and skills, which they
     otherwise lose because their worktrees live elsewhere. The user may decline if that file is
     too broad for the workers; then you pass them what they need in the task text instead. A repo
     that should not get it (one whose own notes are enough) takes `"context": ""` in its entry.
   - `max_workers`: 2. Each worker is a full Claude Code session; more at once costs more usage and
     machine, and their test runs compete.

   Show the whole file, write it only after the user agrees, and mention it is personal until they
   choose to commit it. That message asks about the config alone: no workers, no tasks, no
   change to a repo's files. A yes to it approves the file and nothing else; the workers are
   confirmed later, in their own message (Dispatching, step 4). Then, if this folder is a git repository and `git check-ignore -q
   .claude/mcv.json` fails (the file is not ignored), say so in one line and offer, recommending
   the first: add `.claude/mcv.json` to `.git/info/exclude` (this repository, this machine only,
   no change to the team's files); add `**/.claude/mcv.json` to their global git ignore file (every
   project on this machine); or leave it for them to commit. Never edit the project's
   `.gitignore` for this. If a repo has files the workers need that git ignores (a test account's
   `.env`, say), tell the user they can list them in a `.worktreeinclude` file at that repo's root
   (`.gitignore` syntax); `spawn` copies them into each worktree. Creating that file changes the
   repo, so it is a question of its own, asked after the config is settled.

   Then tell the user in one line which permission mode workers will run in. A worker takes it
   from the Claude Code settings files, not from this session's flags: read
   `permissions.defaultMode` in `~/.claude/settings.json`, then the repo's `.claude/settings.json`
   and `.claude/settings.local.json` (a later file wins, except that `auto` and
   `bypassPermissions` count only from `~/.claude/settings.json`; none means `default`). If it is
   `auto` or `bypassPermissions`, say workers will act without asking anyone, and that mcv refuses only their
   git commands that reach past their own branch. To have a worker ask first, start it with
   `-- --permission-mode default`; it then stops at each approval, which the user answers in its
   herdr pane.
4. **One watcher is running.** If you have not started it in this session, start it with the Monitor
   tool: `BIN/mcv-watch <project>`, with the description `⧉ mcv · <project>` exactly (it is shown
   after every event). The Monitor tool ends it after a while (30 minutes, seen in
   use); while workers are still active, start it again, which shows the open questions again
   (relay none twice). Never start a second one for the same project. If it exits at
   once saying a watcher is already running, check your Monitor tasks: if that one is yours, keep
   using it; if not, another session is watching this project, so tell the user, with the pid the
   message gives, and let them choose to stop it (`kill <pid>`) or work from that session.

## Apply

### Dispatching work

The user names the work. If they started this skill without a task (`/mcv` alone), set up what
the pre-conditions need, then ask what the workers should do. Never pick tasks yourself from a
plan, a queue, a lots file or a tracker, even one that looks ready: you may say what you see
there, in one line, but the user chooses.

1. **Pick the repo.** If the user named it, use it. Otherwise infer it from the task (a file path,
   an app name, an issue that names the app). If it is still unclear, ask in one line, with your
   best guess first.
2. **Name the task.** Pick a short id from the work itself (`cart-fix`, `loyalty-csv`): lowercase,
   digits and `-`, unique in this project, and short enough that `<project>-<id>` is at most 32
   characters. Pick a new branch name following the project's own convention if its CLAUDE.md or
   CONTRIBUTING has one, else `fix/<what>` for a fix and `feat/<what>` for anything else
   (`fix/cart-total`, `feat/loyalty-csv`).
3. **Write the task so the worker can do it without you.** The worker sees its own repo, plus the
   `context` folder if the config has one, and nothing of this conversation. Put in the task text
   the facts it needs that it cannot find there: a decision the user made, an endpoint and its
   shape, the absolute path of a sibling repo it should read (a `../other-repo` written in its
   repo's notes does not resolve from a worktree), a related branch. Facts, not a pointer to read a
   whole file.
4. **Confirm before starting.** Show every worker you are about to start and wait for a yes. This
   message asks only this; a yes the user gave to anything else (the config, a file change) does
   not start a worker. The user may rename ids or branches here. When the repos' bases differ, add each worker's base
   to its line (`branch fix/cart-total from origin/develop`); when their contexts differ, say
   which workers get none (`no project notes`). At most `max_workers` (default 2) workers are active at
   once. A worker is active from its `spawn` until it reports `done` or `failed`, is `gone`, or is
   removed; waiting at a dialog or on a question still counts, and so does one whose Claude failed
   to start until the user lets it through or it is removed. Say which workers wait, and start them
   in this order as active ones end. The queue lives only in this conversation; tell the user so.

   ```
   Starting 2 workers, 1 waiting:
     cart-fix     -> web, branch fix/cart-total     task: add the oat-milk surcharge to the cart total
     loyalty-csv  -> api, branch feat/loyalty-csv   task: export loyalty points as CSV
     receipt-pdf  -> api, branch feat/receipt-pdf   (waits for one of the above)
   OK? (names can be changed)
   ```
5. **Start each worker.** `BIN/mcv-herdr.sh spawn <project> <id> <repo path> <branch>`, adding
   `--base <base>` when that repo's settings have one and `--context <absolute path of context>`
   when they have one, except for a repo that is the context folder itself (the project root listed
   among `repos`): it already has that folder's notes, and `spawn` refuses a context inside the
   repository. Claude's own flags go after `--`; `spawn` refuses `--add-dir` and `--settings`
   there (either form), and `--base`/`--context` too. It
   prints the task, worktree, branch, base, context and how many files it copied from
   `.worktreeinclude`. If it fails, tell the user its one-line reason. If Claude failed to start,
   the reason ends with the last lines of the worker's pane ("its pane shows: ..."); `BIN/mcv-herdr.sh
   read <project>/<id>` shows more. Describe it. Usually it is Claude's folder trust dialog, whose
   default answer is "No, exit": ask the user to pick "Yes" in the worker's herdr pane, then go on
   with step 6. It comes once per repository; later workers there start without it. Something the
   shell asked before Claude started (an update prompt, say) took part of the claude command: tell
   the user what it asked and how to stop it asking, then `remove` and spawn again. If the user
   does not want it, offer `remove`.

   herdr keeps each worker's workspace under a workspace for its repository's main checkout,
   opening one if none is open. The first time you start workers, tell the user in one line:
   closing that repository workspace in herdr closes its workers with it.
6. **Send the task.** `BIN/mcv-herdr.sh prompt <project>/<id> "<dispatch, with {task} replaced>"
   --no-wait`. It returns within seconds with the state `working` (or `blocked` if the worker hit a
   dialog at once). Never call `prompt` without `--no-wait`: Claude Code's Bash tool stops waiting
   after 2 minutes. If it refuses because the worker has no mcv worker rules yet, `read` its
   screen. At Claude's folder trust question, ask the user to pick "Yes" in its pane, then send
   again. Otherwise the mcv plugin is not loaded in that worker: tell the user, offer `remove`,
   and start no more workers until it is fixed; every worker would have the same problem.
7. Tell the user the workers are running, and carry on with the conversation. The watcher wakes you.

The worker's own rules (how to ask, git rules, staying in its worktree) reach it through mcv's
hooks. Do not repeat them in the task text. A hook also refuses a worker's git command that pushes
to another branch, force-pushes, or deletes or moves another branch or a tag; the worker is told to
ask instead, so such a need comes to you as a question like any other.

### Handling what the watcher reports

Each line from the watcher is one event: `⧉ <id> · <EVENT>[ qN] · <text>`. When the watcher starts
(a new session, or after it was restarted) it first shows every question still without an
answered or pending line, so nothing asked earlier is lost; an answer still pending comes as
`DELIVER` once the worker has stopped. A question whose `<id> #<n>` you already relayed in this
conversation is the same question: do not ask the user twice.

The Monitor tool cuts a long event short and ends it with `...(truncated)`. The full line is in
the task's `status.log` (`$MCV_HOME/<project>/tasks/<id>/status.log`, the `needs-decision` line
with that id, say): read it there before relaying, and never relay a cut text.

| Event | What to do |
|---|---|
| `QUESTION qN · <text>` | Relay it to the user as a question card (below). |
| `BLOCKED · <text>` | The worker says it cannot continue. Tell the user why and ask what to do. |
| `WAITING` | The worker stopped at a dialog on its screen. `read` it, describe in plain words what it wants (which command, which file, which question), and ask the user. Never approve it yourself; in this version the user approves or denies in the worker's herdr pane. If it is the folder trust question of a worker whose `spawn` just failed and you already asked about it, it is the same dialog: do not ask again. |
| `RESUMED` | The dialog is gone: the user answered it in the worker's pane. Stop asking them about it; say in one line that the worker went on. |
| `STOPPED` | The worker's turn ended without a report. This is not "finished": a worker waiting on background work (a sub-agent, a build) ends turns too, and its last `NOTE` says so. `read` its screen. If it is waiting on something, say nothing, or one line if the user is waiting on it. If it asked something in plain text, relay that as a question labelled `<id> (on screen)`. Report a task as finished only on `DONE`. |
| `DONE · <text>` | Report the summary. Ask whether to remove the worker; do not remove it unasked. Start the next waiting worker, if any. |
| `FAILED · <text>` | Report the reason and ask what to do next. Start the next waiting worker, if any. |
| `NOTE · <text>` | Mention it in one line, or not at all if it changes nothing for the user. |
| `DELIVER qN · <answer>` | The worker has stopped, and the user's answer to `<id> #N` is still waiting to be sent (step 4 below). `read` its screen. If it is still waiting on that question, send this exact answer with `prompt --no-wait` and record `answered`; do not ask the user again. If it has moved on (asked something else, or reported done), the answer was not given in its pane: tell the user, and ask whether to send it anyway, saying it answers `<id> #N`; record `answered` only once it is sent or the user drops it ("dropped by the user"). If `prompt` refuses as busy, record `pending` again. A `DELIVER` comes once per pending line. |
| `GONE` | The worker is no longer running Claude: its pane was closed, or Claude exited in it. Tell the user; its task and branch remain; offer `remove`. If an answer to it is still pending, say it was never delivered. Start the next waiting worker, if any. |

If `prompt` says a worker is not running Claude any more, handle it like `GONE`: `read` its screen
for what it said last, tell the user, and offer `remove`.

In this version every question goes to the user. Do not answer one yourself, even when you think
you know.

### How mcv looks to the user

Everything mcv shows the user carries the mark `⧉`, so it stands out from the rest of the
conversation. The body of a message is in the user's language; the mark, the ids, the event words
and the reply line stay as written here. No boxes or rules drawn around a message: characters
with combining marks break their alignment.

**Relaying.** Open each relayed event with its header line, then the details indented by two
spaces, then a blank line and what the user does: the exact reply to type, where to click, or
"nothing to do". Events that arrive together go in one message, one block each.

```
⧉ cart-fix · QUESTION #1
  web · fix/cart-total

  Add the surcharge per drink, or once per order?

  1  per drink, as the till prints it on the receipt      ← recommended
  2  once per order

  Reply  cart-fix #1 1
```

```
⧉ cart-fix · WAITING
  Wants to run: git push -u origin fix/cart-total

  Approve or deny it in the herdr pane "mcv shop/cart-fix". I never approve for you.
```

```
⧉ cart-fix · DONE
  3 files staged · tests pass · commit message drafted

  Next  say "commit" when ready
```

```
⧉ cart-fix · FAILED · spawn
  Claude did not start. Last lines of its pane:
    Would you like to update? [Y/n]
    zsh: command not found: laude

  Cause      the shell asked about an update before claude started
  Suggested  stop that prompt, then start the worker again
```

Label questions `<id> #<n>`, with repo and branch on the line under the header, so two workers in
the same repo never look alike. Keep the worker's recommendation and mark it. If a question holds
two decisions, number them `#<n>a` and `#<n>b` in the card and ask for both.

**Commands.** Give every helper call a Bash description that starts with `mcv:` and says what it
does in words: `mcv: start worker cart-fix`, `mcv: send answer to cart-fix #1`, `mcv: read
cart-fix's screen`. Never leave the description to show the helper's full path.

**Where things stand.** One header line, then a table:

```
⧉ mcv · shop · 2 workers

  worker       repo  branch              state      since  you
  cart-fix     web   fix/cart-total      QUESTION   3m     answer #1
  loyalty-csv  api   feat/loyalty-csv    working    12m    —
```

### Sending an answer

1. Match the user's reply to a label. If it could fit more than one question, or does not clearly
   answer one, ask back. Never guess.
2. `BIN/mcv-herdr.sh read <project>/<id>` first. If the worker is still waiting on that question,
   send the answer with `BIN/mcv-herdr.sh prompt <project>/<id> "<answer to <id> #<n>: ...>" --no-wait`,
   then record it: `BIN/mcv-status --task <project>/<id> answered q<n> "<answer>"`.
3. If the worker has moved on (the user answered in its pane), send nothing and record
   `BIN/mcv-status --task <project>/<id> answered q<n> "answered by the user in the worker's pane"`.
4. If `prompt` refuses because the worker is busy, it did not end its turn after asking. Do not
   retry in a loop, and do not just wait: no event would come, since the question already woke
   you. Keep the answer: `BIN/mcv-status --task <project>/<id> pending q<n> "<answer>"`. The
   watcher prints `deliver q<n> <answer>` as soon as the worker stops (at once if it already
   has); then send it and record `answered`. Tell the user the answer goes in when the worker
   stops.

### When the user asks where things stand

`BIN/mcv-herdr.sh agents` lists every herdr agent with its state; mcv workers are named
`<project>-<id>`. Tasks are the folders under `$MCV_HOME/<project>/tasks/` (`MCV_HOME` defaults to
`~/.claude/mcv`). A question is open
when its `needs-decision` line in that task's `status.log` has no `answered` line with the same id.
Report per worker: id, repo and branch, state, since when, and what the user has to do, as the
table under "How mcv looks to the user".

## Verification

- After `spawn`: the printed JSON has the task, branch and base you confirmed with the user, and
  the context that repo's settings name (printed with symlinks resolved, so `/tmp` shows as
  `/private/tmp` on macOS: compare the folder, not the spelling).
- At no time are more than `max_workers` workers active.
- After `prompt --no-wait`: the state is `working`, or `blocked` (then handle it as a dialog).
- After every answer: the task's log has an `answered` line for that question id.
- Before the user leaves: list any worker still running and any open question.

## Rollback

- A worker: `BIN/mcv-herdr.sh remove <project>/<id>`, only when the user agrees. It closes the
  worker, deletes its worktree folder and task state, and keeps the task's record in the folder it
  prints as `history`. It keeps the branch as a local branch (`branch_kept`), unless the branch
  never moved from where it started, has no upstream and no remote has it (`branch_deleted`):
  then it held no work. After the repository's last worker, it closes the repository workspace
  herdr opened for the workers, if nothing runs in it (`closed_workspace`). It
  refuses while the worker is working or at a dialog, and while the worktree has uncommitted or
  untracked files; then tell the user, whose call it is.
- The config: delete `.claude/mcv.json`.

## Operating rules

- Talk to the user in plain language. They never need a script name or a herdr id.
- Never do a worker's task yourself, never answer its questions in this version, never approve a
  dialog on its screen, and never type into its pane other than through `prompt`.
- Never remove a worker, delete a branch, push or merge on a worker's behalf unless the user asks.
- Exactly one watcher per project per session. Every event wakes you, so act on it and stay brief.
- Keep the journal. The helpers already log every `spawn`, `prompt` and `remove` in
  `$MCV_HOME/<project>/journal.log`. Add a line yourself when something did not go as this skill
  says: a step that took more than one try, an event you could not place, a worker that needed
  help it should not have, the watcher ending and being restarted. `BIN/mcv-status --journal
  <project>[/<id>] "<what happened, in one line>"`. Facts only; it is read later to fix mcv.
- Keep herdr running while workers run. Whether workers survive when every herdr window is closed
  is untested.
