# 0005. A coordinator over several projects

- Status: Proposed (revisit after the first full run on a real project)
- Date: 2026-11-07

## Context

The coordinator is started inside one project ([ADR 0002](0002-coordinator-is-a-skill.md)). Some
days a user works across several at once, for example the Brewly project folder from the README
(three repositories under `~/code/brewly`) and a single-repository project such as
`~/code/menu-board`, the café's in-store menu screen, and would rather follow all their workers from one
session than from one session per project.

The code already allows it: `spawn` takes any repository path, and `--base` and `--context` per
call. The project config does not: `repos` paths are relative to the project root, and `base` and
`context` are one value for every repository, while such a set needs different values (a context
for the apps inside a project folder, none for a single repository; possibly different bases).

## Proposal

Start the coordinator in a folder of its own, a "hub", whose `.claude/mcv.json` lists repositories
anywhere, each with its own settings when it needs them:

```json
{ "project": "hub",
  "repos": {
    "menu-board": "/Users/me/code/menu-board",
    "web":        { "path": "/Users/me/code/brewly/web",
                    "context": "/Users/me/code/brewly",
                    "base": "origin/develop" } },
  "max_workers": 3 }
```

A string stays a plain path, so existing configs keep working; an object adds `path`, `context`,
`base` and later anything else per repository. Paths may be absolute. Only the skill and the README
change; the scripts already take these per call.

## Trade-offs

- The hub coordinator has no project's CLAUDE.md, skills or memory, the gap ADR 0001 held against
  firstmate. Project-specific procedures (a planning skill that lives in one project) are not
  available there; for such work, the coordinator inside that project remains the right place.
- One `max_workers` spans every project, which is the point (one machine, one usage budget).
- An alternative is a hub whose workers are the per-project coordinators. It keeps each project's
  context, at the cost of a second layer of relaying.

## Decision

None yet. Decide after the first full run, if the user wants the hub.
