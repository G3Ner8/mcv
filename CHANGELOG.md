# Changelog

All notable changes to mcv are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and mcv uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

First version. Experimental: every part is in place and checked on its own, against herdr 0.9.5
and Claude Code 2.1.318 where it could be; a full run on a real project, from the first task to a
merge request, is still to do.

### Added

- `bin/mcv-herdr.sh`, the only file that calls herdr: `doctor`, `spawn`, `prompt`, `read`, `agents`,
  `remove`.
  - A worker gets `MCV_TASK` and `MCV_HOME` through Claude's own `--settings`, so nothing is typed
    into its shell first.
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
    its SessionStart hook), which would otherwise work with no git rules and never report.
- `bin/mcv-status`: the worker's append-only status log (`needs-decision` with a numbered question,
  `blocked`, `done`, `failed`, `note`). Writes hold a lock, so question ids never repeat. The
  coordinator closes a question with `--task <project>/<id> answered`; a worker cannot. An answer
  to a worker still busy after asking is kept with `--task ... pending` until it can be sent. It also
  prints the rules the hooks give a worker: a fixed git floor (its own branch only, no force-push,
  no secrets), then the project's own git rules, or common practice where a project has none.
- `bin/mcv-watch <project>`: one event stream for Claude Code's Monitor tool. Prints only what is
  worth a coordinator turn, and on start the questions still open. A pending answer comes back as
  a `deliver` event when the worker stops. Survives damaged state, an
  unreadable log and herdr being down; stops at once on TERM.
- `hooks/hooks.json`: SessionStart gives a worker its rules; PreToolUse refuses AskUserQuestion with
  directions to `mcv-status needs-decision`. Both do nothing unless `MCV_TASK` names a task mcv
  started.
- `skills/mcv/SKILL.md`: the `/mcv` skill the coordinator follows. Builds `.claude/mcv.json` with the
  user (proposing `base` and `context` where they matter), confirms every worker before starting
  it, keeps at most `max_workers` active, labels questions `<task id> #<n>`, writes into each task
  the facts the worker cannot find itself, reads the worker's screen before sending an answer, and
  never answers a question or approves a dialog for the user.
- Tests: 323 checks in `tests/`, against a fake herdr that does the git work for real, passing on
  macOS (bash 3.2); the first 300 also on Ubuntu 24.04. Four adversarial QA passes; every fix came
  with a regression test that failed before it.
