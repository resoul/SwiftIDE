#!/bin/zsh
# Rewrites the Swift code of the repository to the agreed style (TK-023). Explicit, never run by a
# build. Commit its result apart from any functional change.
#   Tools/Lint/format.sh
set -eu
source "${0:A:h}/common.sh"
cd "$ROOT"
prepare

# Order matters: the one-line bodies of too-long lines go onto lines of their own first, so that SwiftFormat
# wraps only what is left of the line; the blank lines are added once more after it.
"$SPACING" --fix "${SOURCES[@]}" "${SPACING_EXCLUDES[@]}"
"$LINT/.tools/swiftformat" .
"$SPACING" --fix "${SOURCES[@]}" "${SPACING_EXCLUDES[@]}"
echo "format: done; run Tools/Lint/lint.sh to confirm"
