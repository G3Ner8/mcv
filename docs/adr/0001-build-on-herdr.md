# 0001. Build our own coordinator on herdr

- Status: Accepted
- Date: 2026-11-06

## Context

Running several Claude Code sessions on one project needs one session that starts the others,
hands them tasks and passes their questions to the user. An existing tool,
[kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), does this in shell. Read at
commit 8b1618a4 (2026-11-05):

- Its coordinating session runs from firstmate's own repository, outside the project, so it never
  loads the project's CLAUDE.md, skills or memory, and its rules forbid it to write to the project.
  The coordinator's context (planning, task lists, conventions) lives in the project.
- It is large and moves fast: about 425k lines of shell including tests, 256 commits in 30 days, and
  its own family of helper tools. It would be a dependency to track, not a tool to use.
- It keeps its own clones of each project, so files a project needs that git does not track do not
  follow into its worktrees.

[herdr](https://herdr.dev) is a terminal workspace manager for coding agents: it creates git
worktrees, runs each agent in its own pane, and lets a script start an agent, send it a prompt, read
its screen and see whether it is busy, waiting at a dialog, or finished.

## Decision

Build mcv: a Claude Code plugin whose coordinator runs inside the project, on top of herdr, which
does the process and worktree work. mcv keeps only the bookkeeping: tasks, questions, answers, the
project config and the coordinator's procedure. Every herdr call lives in one file,
`bin/mcv-herdr.sh`. No second backend (tmux and the like) until someone needs one.

Ideas taken from firstmate: an append-only status log where a line is a wake event, not the current
state; the coordinator's answer closes the question in the log; message plane separate from control
plane; refuse to run a worker in the primary checkout; a user typing into a worker's window wins;
no wrappers until the direct path shows a concrete blocker.

## Consequences

- herdr is a hard requirement, with its Claude integration current; `doctor` checks both.
- A change in herdr's CLI is fixed in `bin/mcv-herdr.sh` alone.
- mcv is tested against a fake herdr that does the git work for real; what only herdr shows is
  checked by hand and recorded in [architecture.md](../architecture.md).
