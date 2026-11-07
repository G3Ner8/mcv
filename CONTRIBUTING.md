# Contributing to mcv

How to work on mcv itself. For what mcv does and how to use it, read the [README](README.md); for
how it is built, [docs/architecture.md](docs/architecture.md).

## Setup

You need bash 3.2 or newer, git 2.28 or newer (the tests use `git init -b`), jq 1.5 or newer, and
[shellcheck](https://www.shellcheck.net/) for linting. herdr is not needed for the tests; it is for
trying a change for real.

To try a change in Claude Code without installing it, start a session with the plugin loaded from
your clone:

```
claude --plugin-dir /path/to/mcv
```

and pass the same flag to the workers you start by hand: `bin/mcv-herdr.sh spawn ... -- --plugin-dir
/path/to/mcv`. Without it, a worker has no mcv hooks, and `prompt` refuses it.

## Layout

```
.claude-plugin/   plugin.json (the plugin) and marketplace.json (this repo is its own marketplace)
skills/mcv/       SKILL.md, the coordinator's procedure
hooks/            hooks.json; both hooks do nothing unless MCV_TASK names a task
bin/              mcv-herdr.sh (the only file that calls herdr), mcv-status, mcv-watch
tests/            test-*.sh, run.sh, fixtures/ (fake-herdr.sh, stub-herdr.sh)
docs/             architecture.md, adr/ (decision records)
```

## Checks

```
make check        lint, JSON and versions, then the whole test suite (about a minute)
make test         the test suite only
make test-hooks   the hook-guard test alone (what CI runs)
make lint         shellcheck: bin/ at style level, tests/ at warning level
```

Run `make check` before every commit. CI runs only lint, the JSON check and the hook-guard test: the
rest of the suite starts many processes at once or measures time, which a shared runner does
badly, and the runner is kept light on purpose.

## Writing code

- **bash 3.2 compatible.** macOS still ships it: no associative arrays, no `${var,,}`, no `mapfile`,
  and guard empty arrays under `set -u` (`${a[@]+"${a[@]}"}`). Each script starts with
  `set -euo pipefail`.
- **shellcheck clean.** A `# shellcheck disable=` line needs a comment saying why.
- **All herdr calls in `bin/mcv-herdr.sh`.** Every other file goes through it, so a change in herdr's
  CLI is fixed in one place.
- **Errors are one line** on stderr, `mcv-herdr: <command>: <reason>`, exit 1. No raw shell or jq
  error reaches the caller. Exit 2 means the caller asked for something the script does not have:
  an unknown command in `mcv-herdr.sh` (which then prints its usage text), and an unknown kind or
  a worker kind without `MCV_TASK` in `mcv-status`. Wrong arguments to a known `mcv-herdr.sh`
  command are an error like any other: one line, exit 1.
- **Hooks stay opt-in.** A plugin hook runs in every session where mcv is installed. It must exit 0
  with no output unless `MCV_TASK` names a task mcv started; `tests/test-hooks.sh` checks this.
- **Comments are plain prose** and say why, not what. No markers or emoji in code comments.

## Tests

- Write the failing test first, see it fail against the current code, then fix.
- Tests use `tests/fixtures/fake-herdr.sh`, which does the git work for real, so git behaves as it
  does under herdr. Never call the real herdr from a test, and never touch `~/.claude/mcv`: point
  `MCV_HOME` at a temporary folder.
- A behaviour that only real herdr or a real Claude worker can show (a dialog, a signal, what a
  worker sees) is checked by hand; say in the pull request what you ran and what it showed.

## Commits and pull requests

- Branch from `main`; never commit to it directly.
- [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope):`, `fix(scope):`,
  `docs:`, `test:`, `ci:`, `refactor:`. The body says why, and what was checked.
- One change per pull request. Its description says what changed, why, and how it was tested,
  marking what was run against real herdr apart from what only the tests show.
- A decision that changes how mcv is built, or rules something out, gets an ADR in `docs/adr/`.

## Releases

mcv uses [SemVer](https://semver.org/). To release:

1. Set the same version in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
   (`make json` checks they match) and in the skill's `metadata.version` if the skill changed.
2. Move the `Unreleased` entries in `CHANGELOG.md` under the new version and date.
3. Merge, then tag the merge commit `vX.Y.Z` and push the tag.

The marketplace version is the cache key: installed copies update only when it changes.
