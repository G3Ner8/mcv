# 0002. The coordinator is a skill in the user's own session

- Status: Accepted
- Date: 2026-11-06

## Context

Claude Code offers two shapes for behaviour: a skill, which the current session follows, and a
subagent, which runs one-shot and returns a report. Multi-step orchestration usually belongs in an
agent. But the coordinator talks to the user for the whole session, and is woken by a watcher
(through Claude Code's Monitor tool) whenever a worker asks a question or stops. A one-shot subagent
can do neither.

## Decision

The coordinator is the user's own main session following the `/mcv` skill, started inside the
project, so it has the project's CLAUDE.md, skills and memory. One coordinator per project. Workers
are full Claude Code sessions, not subagents, so a worker can run for a long time, ask questions
along the way, and be looked at or taken over by the user in its own pane.

## Consequences

- The user keeps talking to one session; questions from every worker arrive there, labelled
  `<task id> #<n>`.
- Short, self-contained tasks that need no decisions along the way are cheaper as subagents in one
  session; mcv is for work that needs the user mid-way.
- A coordinator over several projects at once is a separate question:
  [ADR 0005](0005-hub-coordinator.md).
