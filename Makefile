.PHONY: check test test-hooks lint json version-check

SCRIPTS := bin/mcv-herdr.sh bin/mcv-status bin/mcv-watch
TESTS := tests/run.sh $(wildcard tests/test-*.sh) $(wildcard tests/fixtures/*.sh)
JSON := .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json
# What an installed copy runs. A change here reaches users only with a new
# version, because Claude Code keys its plugin cache on the version.
SHIPPED := bin skills hooks .claude-plugin
BASE ?= origin/main

# Everything a change must pass before it is committed.
check: lint json version-check test

# The whole suite, against a fake herdr. Takes two to three minutes, most of it
# the lock-contention rounds in test-spawn.sh and test-status.sh.
test:
	@tests/run.sh

# The hook-guard test alone: what CI runs.
test-hooks:
	@tests/run.sh test-hooks.sh

lint:
	shellcheck -x -S style $(SCRIPTS)
	shellcheck -x -S warning $(TESTS)

# Valid JSON, and one version in plugin.json, marketplace.json and the skill.
json:
	@for f in $(JSON); do jq -e . "$$f" >/dev/null || { echo "invalid JSON: $$f"; exit 1; }; done
	@v1=$$(jq -r .version .claude-plugin/plugin.json); \
	 v2=$$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json); \
	 v3=$$(sed -n 's/^  version: "\(.*\)"$$/\1/p' skills/mcv/SKILL.md | head -1); \
	 [ "$$v1" = "$$v2" ] && [ "$$v1" = "$$v3" ] \
	   || { echo "version mismatch: plugin.json $$v1, marketplace.json $$v2, SKILL.md $$v3"; exit 1; }
	@echo "json ok"

# A change to what users install needs a new version, or installed copies
# never receive it. Compares the working tree with where it left BASE
# (default origin/main), so uncommitted changes count too.
version-check:
	@changed=$$(git diff --name-only "$$(git merge-base "$(BASE)" HEAD)" -- $(SHIPPED)); \
	 if [ -z "$$changed" ]; then echo "version ok: nothing shipped changed since $(BASE)"; exit 0; fi; \
	 old=$$(git show "$(BASE)":.claude-plugin/plugin.json | jq -r .version); \
	 new=$$(jq -r .version .claude-plugin/plugin.json); \
	 if [ "$$old" = "$$new" ]; then \
	   echo "version not raised: $$(echo $$changed | tr ' ' ',') changed since $(BASE), but the version is still $$new;"; \
	   echo "raise it in .claude-plugin/plugin.json, .claude-plugin/marketplace.json and skills/mcv/SKILL.md"; \
	   exit 1; \
	 fi; \
	 echo "version ok: $$old -> $$new"
