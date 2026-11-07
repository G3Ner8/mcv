# 0003. Give workers the project around them with --context and .worktreeinclude

- Status: Accepted
- Date: 2026-11-06

## Context

A worker's worktree is made from git and lives under `~/.herdr/worktrees/`, outside the project's
folders. A session opened in a repository's own folder has more than git holds, and a worker loses
it:

- When the repository sits inside a project folder that holds several repositories, Claude Code
  loads that folder's CLAUDE.md and CLAUDE.local.md as a parent of the session's folder, and its
  skills through symlinks. From a worktree elsewhere, none of that loads, and a path such as
  `../plans/menu-v2.md` in the repository's notes points at nothing.
- Files git ignores do not come along: a test account's `.env`, local settings.

Measured on a real app repository: dependencies install in about a minute in a fresh worktree, but
its browser checks cannot run without an ignored `qa/.env`.

Three ways were considered: run workers in the existing checkout instead of a worktree (one worker
per repository, the user's checkout in use); move each project to fit worktrees (commit what is
ignored, rewrite paths); or give the worktree what it lacks.

## Decision

Give the worktree what it lacks, keeping one worktree per worker:

- `spawn --context <folder>` starts Claude with `--add-dir <folder>` and
  `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`, which loads that folder's CLAUDE.md,
  CLAUDE.local.md and skills. Because `--add-dir` also allows edits, the worker's settings deny
  Claude's file edits there, and its rules call it read-only and say what `../` means.
- `.worktreeinclude` at a repository's root, in `.gitignore` syntax (the file Claude Code uses for
  its own worktrees), names ignored files to copy from the main checkout. The worktree's own git
  decides: a file is copied only if the base branch ignores it and has no file there.
- Dependencies are installed by the worker, as the repository's own notes say; they are not copied.

## Consequences

- Several workers can work in one repository at once, and the user's checkout is never touched.
- Checked with real workers: the project folder's notes and skills arrive, copied files arrive, an
  edit in the context folder is refused. A shell command could still write there.
- `context` is one value per project config today; a config spanning several projects needs it per
  repository ([ADR 0005](0005-hub-coordinator.md)).
