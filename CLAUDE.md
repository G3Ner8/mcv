# mcv

A Claude Code plugin: one session (the coordinator, following `skills/mcv/SKILL.md`) starts other
Claude Code sessions (workers) in their own git worktrees through herdr, and relays their questions
to the user. What it does: [README.md](README.md). How it is built: [docs/architecture.md](docs/architecture.md).
Why: [docs/adr/](docs/adr/). How to work on it: [CONTRIBUTING.md](CONTRIBUTING.md), which holds the
rules below in full.

## Commands

```
make check        lint, JSON and versions, version raised, the whole suite (under a minute);
                  before every commit
make test         the suite only (tests/run.sh; tests/run.sh test-x.sh runs one file)
make lint         shellcheck
```

## Rules that are easy to break

- **bash 3.2.** No associative arrays, `mapfile`, `${var,,}`; guard empty arrays under `set -u` with
  `${a[@]+"${a[@]}"}`.
- **Only `bin/mcv-herdr.sh` calls herdr.** Every other file goes through it.
- **Hooks stay opt-in.** `hooks/hooks.json` runs in every session where mcv is installed; it must
  exit 0 with no output unless `MCV_TASK` names a task mcv started. `tests/test-hooks.sh` guards it.
- **Tests never call the real herdr and never touch `~/.claude/mcv`.** Use
  `tests/fixtures/fake-herdr.sh` and point `MCV_HOME` at a temporary folder. Write the failing test
  first.
- **One behaviour, four descriptions.** A command's behaviour is written in the usage header at the
  top of its script, in the README, in `skills/mcv/SKILL.md` and in `docs/architecture.md`. A change
  to what a command accepts, prints or refuses updates every one that mentions it.
- **A shipped change needs a new version.** Installed copies update only when the version
  changes, so a change to `bin/`, `skills/`, `hooks/` or `.claude-plugin/` raises it in
  `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and the skill's
  `metadata.version` together, with a CHANGELOG section. `make json` checks the three match;
  `make version-check` (in `make check`, and CI on pull requests) checks it was raised.
- **Comments are plain prose** that say why. No markers or emoji in code comments.
