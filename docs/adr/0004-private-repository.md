# 0004. A private repository of its own until mcv is proven

- Status: Accepted
- Date: 2026-11-07

## Context

mcv is more than a skill: it ships executables, hooks and a test suite, and depends on herdr. It has
not yet been used end to end on a real project, and its author wants to use it privately until it
has, then decide whether to share it.

## Decision

mcv lives in a repository of its own, private for now. The repository is its own marketplace
(`.claude-plugin/marketplace.json`, source `./`), so it installs with
`/plugin marketplace add <owner>/mcv` and `/plugin install mcv@mcv`, with no other marketplace
involved.

## Consequences

- mcv keeps its own conventions: decision records in `docs/adr/`, shellcheck, a Makefile as the one
  entry point for checks, a light CI.
- Installing from a private repository needs git access to it on the machine.
- To share it later: make the repository public. Any other marketplace can list it by its git
  source, so it installs from there too.
