.PHONY: check test test-hooks lint json

SCRIPTS := bin/mcv-herdr.sh bin/mcv-status bin/mcv-watch
TESTS := tests/run.sh $(wildcard tests/test-*.sh) $(wildcard tests/fixtures/*.sh)
JSON := .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json

# Everything a change must pass before it is committed.
check: lint json test

# The whole suite, against a fake herdr. Takes about a minute.
test:
	@tests/run.sh

# The hook-guard test alone: what CI runs.
test-hooks:
	@tests/run.sh test-hooks.sh

lint:
	shellcheck -x -S style $(SCRIPTS)
	shellcheck -x -S warning $(TESTS)

json:
	@for f in $(JSON); do jq -e . "$$f" >/dev/null || { echo "invalid JSON: $$f"; exit 1; }; done
	@v1=$$(jq -r .version .claude-plugin/plugin.json); \
	 v2=$$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json); \
	 [ "$$v1" = "$$v2" ] || { echo "version mismatch: plugin.json $$v1, marketplace.json $$v2"; exit 1; }
	@echo "json ok"
