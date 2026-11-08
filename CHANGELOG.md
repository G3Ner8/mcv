# Changelog

All notable changes to mcv are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mcv uses
[Semantic Versioning](https://semver.org/).

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
