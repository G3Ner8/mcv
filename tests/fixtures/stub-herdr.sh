#!/usr/bin/env bash
#
# Stand-in for mcv-herdr.sh in tests. `agents` prints the file named by
# STUB_AGENTS, which the test rewrites between polls (one line per agent:
# pane id, state, change counter, name; tab-separated). `read` prints the
# file named by STUB_SCREEN as the worker's screen, and fails without one.
# With STUB_DOWN=1 it fails, as when the herdr server is not running.

set -euo pipefail

[[ "${STUB_DOWN:-}" != 1 ]] || { echo "mcv-herdr: agents: herdr server is not running" >&2; exit 1; }

case "${1:-}" in
  agents) cat "${STUB_AGENTS:?STUB_AGENTS not set}" ;;
  read)
    [[ -n "${STUB_SCREEN:-}" ]] || { echo "mcv-herdr: read: no such pane" >&2; exit 1; }
    cat "$STUB_SCREEN" ;;
  *) echo "stub-herdr: only 'agents' and 'read' are supported" >&2; exit 2 ;;
esac
