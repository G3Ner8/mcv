# 0001. Build our own coordinator on herdr

- Status: Accepted
- Date: 2026-11-06

## Context

Running several Claude Code sessions on one project needs one session that starts the others,
hands them tasks and passes their questions to the user. Three things were wanted of it, and they
ruled out adopting a ready-made coordinator that lives outside the project:

- The coordinating session runs inside the project, so it loads the project's CLAUDE.md, skills
  and memory. The coordinator's context (planning, task lists, conventions) lives in the project.
- It is small enough to read and to own: a few shell scripts and one skill, not a dependency to
  track.
- Workers start from the project's own checkout, so the files a project needs that git does not
  track can follow into their worktrees.

[herdr](https://herdr.dev) is a terminal workspace manager for coding agents: it creates git
worktrees, runs each agent in its own pane, and lets a script start an agent, send it a prompt, read
its screen and see whether it is busy, waiting at a dialog, or finished.

## Decision

Build mcv: a Claude Code plugin whose coordinator runs inside the project, on top of herdr, which
does the process and worktree work. mcv keeps only the bookkeeping: tasks, questions, answers, the
project config and the coordinator's procedure. Every herdr call lives in one file,
`bin/mcv-herdr.sh`. No second backend (tmux and the like) until someone needs one.

Principles held from the start: an append-only status log where a line is a wake event, not the
current state; the coordinator's answer closes the question in the log; message plane separate
from control plane; no worker runs in the primary checkout; a user typing into a worker's window
wins; no wrappers until the direct path shows a concrete blocker.

## Consequences

- herdr is a hard requirement, with its Claude integration current; `doctor` checks both.
- A change in herdr's CLI is fixed in `bin/mcv-herdr.sh` alone.
- mcv is tested against a fake herdr that does the git work for real; what only herdr shows is
  checked by hand and recorded in [architecture.md](../architecture.md).
