# Changelog

All notable changes to mcv are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mcv uses
[Semantic Versioning](https://semver.org/).

## [0.2.3] - 2026-11-10

Leftovers from issue #10, and one finding from checking 0.2.2 on herdr.

### Fixed

- An order given while a worker was busy ("push item 1") could only be held in the
  coordinator's memory and retried at each stop (refused four times on carsol).
  `mcv-status --task <t> pending - <text>` queues it under a new order id (`o1`, ...), and the
  watcher hands it back as `DELIVER o1` when the worker stops, like a pending answer.
- A worker's workspace label (`mcv carsol/adm...`) was cut in herdr's sidebar before the task
  name. It is now `⧉ <id> · <project>`: the mark the coordinator's events use, then the task.
  The status table's repo column names the workspace a worker sits under. herdr 0.9.5 offers no
  way to place a workspace elsewhere. When herdr's answer to `worktree create` cannot be read,
  the error now names that label; it named the agent (`acme-t3`), which no workspace shows.
- The coordinator's rule for restarting the watcher said "while workers are still active",
  which left a worker that had reported `DONE` undefined. It now restarts at once while a worker
  is busy, waiting or has a question open, and otherwise just before its next `spawn` or
  `prompt` (as a coordinator did on its own when 0.2.2 was checked on herdr).

## [0.2.2] - 2026-11-09

Fixes from the second real run (three workers, two repositories, issue #10).

### Fixed

- A bare "1" was relayed as the worker's option 1 when the user meant the coordinator's own
  proposal, and the worker acted on the wrong answer. Options in a question card are now letters
  (questions keep numbers), a course the coordinator proposes becomes another lettered option,
  a short reply after the talk has moved on is said back for a yes before it is sent, and the
  answer is sent and recorded with the option's words, not the letter alone.
- A correction to an answer already sent could not be recorded, so the status log disagreed with
  what the worker was told. `mcv-status --task <t> amended <qid> <text>` records it.
- The git guard read `2>&1` as the push target (`refused, this pushes to 2>`), so both workers'
  pushes to their own branches were refused. Redirections are now removed before the command is
  read.
- Every restart of the watcher (the Monitor tool ends it after 30 minutes) showed the open
  questions again and the coordinator announced each restart. `mcv-watch <project> --resume` now
  goes on from where the last watcher stopped; its state is kept under
  `$MCV_HOME/<project>/watch-state`. The coordinator restarts it silently.
- Every note woke the coordinator, and every turn a worker ended while a build or sub-agent ran
  came as `STOPPED`. Notes no longer wake it (they stay in the status table), and a worker that
  ends a turn to wait says so first with the new `mcv-status waiting <text>`; that stop wakes
  nobody unless it lasts past `MCV_WATCH_WAIT_LIMIT` seconds (default 1800). This replaces the
  0.2.1 rule to send a note first. Together these were about a fifth of the coordinator's cost.

## [0.2.1] - 2026-11-09

Fixes from the first real run (two workers on a frontend project, issue #8).

### Fixed

- The coordinator picked a task from the project's plan files when started with `/mcv` alone.
  It now asks what the workers should do and never chooses work itself.
- One "ok" approved the config, a change to the repos' files and the workers at once. The skill
  now asks about each in its own message, and a yes to one never counts for another.
- When the shell in a new pane asked something before Claude started (oh-my-zsh's update
  question took the first letter of `claude`), `spawn` said only "timed out waiting for agent
  startup". Its error now ends with the pane's last lines.
- A dialog the user answered in a worker's pane left the coordinator asking them to approve it
  again. The watcher now prints `RESUMED` when a worker goes from blocked back to working.
- The skill read a turn end with no report (`state done`) as a finished task, though a worker
  waiting on a sub-agent ends turns too. It now treats that as `STOPPED`, reads the screen, and
  reports a task finished only on `DONE`; workers send a note first when they end a turn while
  background work runs.
- A question cut short by the Monitor tool (`...(truncated)`) was relayed as it came. The skill
  now reads the full line from the task's status log.
- `remove` kept a branch with no work on it, so a new spawn of the same name was refused until
  the user deleted it by hand. It now deletes a branch still at its starting commit, with no
  upstream and on no remote; any other branch is kept as before.
- `remove` left open the repository workspace herdr opened for the workers. After the last worker
  of a repository it now closes that one, if it is idle; one the user opened is never closed.

### Changed

- Watcher events read `⧉ <id> · <EVENT> · <text>` (QUESTION, BLOCKED, DONE, FAILED, NOTE, WAITING,
  RESUMED, STOPPED, DELIVER, GONE) instead of tab-separated fields with an ISO time;
  `MCV_WATCH_RAW=1` keeps the old form. The skill gives relayed questions, dialogs, results and
  the status table one fixed shape under the same mark, names the Monitor `⧉ mcv · <project>`, and
  starts its helper calls' descriptions with `mcv:`.
- herdr labels a worker's workspace `mcv <project>/<id>`, so it stands apart from the user's own.
- Workers ask one decision per question, so the user can answer each by its id.
- The README and the skill warn that closing a repository's workspace in herdr closes its workers.

## [0.2.0] - 2026-11-08

### Added

- A git guard for workers: a PreToolUse hook on Bash refuses, before it runs, a git command that
  pushes to a branch other than the worker's own, force-pushes (`--force-with-lease` passes on
  its own branch), pushes every branch or tag, or deletes or moves another branch or a tag. The
  worker is told why and to ask through `needs-decision`. Until now these rules were only text in
  the worker's context, which a worker in auto mode follows unattended. It reads the command's
  text, so it stops mistakes, not a determined worker. Checked with a real Claude worker: `git tag
  -d` was refused before it ran.
- A journal per project, `~/.claude/mcv/<project>/journal.log`: one line for each `spawn`,
  `prompt` and `remove`, done or refused with the reason, and notes the coordinator adds with
  `mcv-status --journal` when something does not go as the skill says.
- Task history: `remove` copies the task's meta, status log and the worker's Claude transcript
  paths to `~/.claude/mcv/<project>/history/<id>-<time>/` before deleting its state, and prints
  the folder. The SessionStart hook records each transcript path from Claude's hook input.
- The coordinator tells the user, when it writes the config, which permission mode workers will
  run in and how to make them ask first.

### Changed

- `remove` keeps the project's folder in `~/.claude/mcv/`, which now holds its journal and history;
  it still removes the `tasks` folder when it is left empty.
- The skill says to restart the watcher when the Monitor tool ends it (after 30 minutes, seen in
  use).

## [0.1.3] - 2026-11-07

### Fixed

- Two processes that found the same stale lock could both take it: `mcv-status`'s log lock
  (repeated question ids, lost questions) and `mcv-herdr.sh`'s claim and repository locks
  (overlapping spawns). Taking over now goes through `<lock>.takeover`, as the watch lock's
  already did. This is the likely cause of the repeated question ids seen once on CI.

### Changed

- README and architecture say that herdr's sidebar lists workers under the workspace it takes as
  the repository's main checkout, which mcv cannot choose.

## [0.1.2] - 2026-11-07

The first release whose changes were made by mcv workers, in a smoke test on this repository.

### Fixed

- `mcv-status` removes the escape sequences 0.1.1 left fragments of: CSI with a private prefix
  (`ESC [ > 4 ; 1 m`), charset designations (`ESC ( B`) and the C1 introducer U+009B.
- `spawn` refuses `--add-dir` and `--settings` after `--`, in either form: the first would open a
  folder the context's deny rule does not cover, the second could override `MCV_TASK`.
- Several watchers starting together on a stale `watch.lock` could all run; taking it over now
  goes through a second lock, `watch.lock.takeover`, so exactly one does.

## [0.1.1] - 2026-11-07

### Added

- The coordinator offers to ignore `.claude/mcv.json` on this machine (`.git/info/exclude`, or
  the global git ignore file) when git does not ignore it; it never edits the project's
  `.gitignore`.
- README: a short "What mcv writes" section.
- CI fails a pull request that changes `bin/`, `skills/`, `hooks/` or `.claude-plugin/` without
  raising the version, since installed copies update only when it changes.

### Changed

- `remove` also removes the folders it leaves empty: the project's state folder and herdr's
  per-repository worktree folder.

## [0.1.0] - 2026-11-07

First version. Experimental: every part is in place and checked on its own, against herdr 0.9.5
and Claude Code 2.1.318 where it could be; a full run on a real project, from the first task to a
merge request, is still to do.

### Added

- `bin/mcv-herdr.sh`, the only file that calls herdr: `doctor`, `spawn`, `prompt`, `read`, `agents`,
  `remove`.
  - A worker gets `MCV_TASK` and `MCV_HOME` through Claude's own `--settings`, so no export is
    typed into its shell first (herdr does type the `claude` command line itself).
  - `spawn` fetches and branches from the remote's default branch, or `--base <ref>`. It refuses a
    branch that already exists, locally or on a remote, compared ignoring case, and always
    `main`/`master`/`develop`, since herdr would check an existing branch out as it is. It clears
    the upstream git gives the new branch, so a plain `git push` cannot reach the base branch.
  - One spawn runs at a time per repository and per worker name. An interrupted spawn undoes what
    it made, or leaves a task `remove` can clean up.
  - `spawn --context <folder>` opens the project folder around the repository to the worker, with
    that folder's CLAUDE.md, CLAUDE.local.md and skills, and denies Claude's file edits there.
  - `.worktreeinclude` names ignored files (a test account's `.env`) to copy into each worktree,
    decided by the worktree's own git so nothing committed is overwritten.
  - `prompt --no-wait` returns as soon as the worker starts, so a caller is never held past Claude
    Code's 2-minute Bash limit. `remove` works after the user closed the worker's workspace.
  - `prompt` refuses a worker whose Claude did not load mcv's hooks (no `rules-loaded` marker from
    its SessionStart hook), which would otherwise work with no git rules and never report; the
    message names the folder trust dialog first, the usual cause, which herdr reports as idle
    or blocked.
  - The base defaults to the only remote's default branch when no remote is called `origin`, and
    several remotes with no `origin` need `--base`, instead of branching from HEAD.
  - A relative `MCV_HOME` is made absolute before it reaches the worker.
  - A claim or lock with no pid is taken over once a minute old; a refused claim names its folder.
  - `spawn` refuses up front, in one line, what git would trip on later: a branch named like a
    tag or a remote, one folder above or below an existing branch, a bare repository, mcv's own
    options after `--`, and a `--context` path with glob characters. A `.worktreeinclude` file
    that cannot be copied says why.
  - `prompt` refuses a missing or empty text; `remove` refuses a worker that is working or at a
    dialog.
- `bin/mcv-status`: the worker's append-only status log (`needs-decision` with a numbered question,
  `blocked`, `done`, `failed`, `note`). Writes hold a lock, so question ids never repeat. The
  coordinator closes a question with `--task <project>/<id> answered`; a worker cannot. Text
  given without quotes is kept whole; empty text is refused; terminal escape sequences are removed
  whole. An answer
  to a worker still busy after asking is kept with `--task ... pending` until it can be sent. It also
  prints the rules the hooks give a worker: a fixed git floor (its own branch only, no force-push,
  no secrets), then the project's own git rules, or common practice where a project has none.
- `bin/mcv-watch <project>`: one event stream for Claude Code's Monitor tool. Prints only what is
  worth a coordinator turn, and on start the questions still open. A pending answer comes back as
  a `deliver` event when the worker stops, once per pending line. One watcher per project: a second one exits at once,
  naming the first's pid. Survives damaged state, an
  unreadable log and herdr being down; stops at once on TERM.
- `hooks/hooks.json`: SessionStart gives a worker its rules; PreToolUse refuses AskUserQuestion with
  directions to `mcv-status needs-decision`. Both do nothing unless `MCV_TASK` names a task mcv
  started.
- `skills/mcv/SKILL.md`: the `/mcv` skill the coordinator follows. Builds `.claude/mcv.json` with the
  user (proposing `base` and `context` where they matter, at the top level or per repository
  with an object entry that wins over them), confirms every worker before starting
  it, keeps at most `max_workers` active, labels questions `<task id> #<n>`, writes into each task
  the facts the worker cannot find itself, reads the worker's screen before sending an answer, and
  never answers a question or approves a dialog for the user.
- Tests: 369 checks in `tests/`, against a fake herdr that does the git work for real, passing on
  macOS (bash 3.2); the first 300 also on Ubuntu 24.04. Four adversarial QA passes; every fix came
  with a regression test that failed before it.
