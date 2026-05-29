#!/usr/bin/env bash
# PostToolUse hook: run oxlint --fix then oxfmt on the edited file.
# Receives Claude Code hook JSON on stdin.

set -uo pipefail

file=$(jq -r '.tool_input.file_path // empty')
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

case "${file##*.}" in
  ts|tsx|js|jsx|mjs|cjs|mts|cts|css|scss|less|md|mdx|json|jsonc|json5) ;;
  *) exit 0 ;;
esac

bin="$CLAUDE_PROJECT_DIR/node_modules/.bin"

# oxfmt runs even when oxlint exits non-zero so formatting always happens;
# lint errors propagate via the final exit code.
"$bin/oxlint" --fix --fix-suggestions --quiet "$file"
lint=$?
"$bin/oxfmt" "$file"
fmt=$?

[ "$lint" -ne 0 ] && exit "$lint"
exit "$fmt"
