# Shared by lint.sh and format.sh. Sourced, not run.
ROOT="${0:A:h:h:h}"
LINT="$ROOT/Tools/Lint"
SOURCES=(Apps/SwiftIDE Packages/IDE)
SPACING_EXCLUDES=(--exclude vendor --exclude Generated)

prepare() {
  "$LINT/install.sh" > /dev/null || { echo "lint: could not install the pinned tools" >&2; exit 2; }
  # The blank-line checker is a SwiftPM package of its own; the build is incremental.
  swift build --package-path "$LINT" -j 2 --product spacing-check 2>&1 | grep -E "error|warning: unre" || true
  SPACING="$LINT/.build/debug/spacing-check"
  [[ -x "$SPACING" ]] || { echo "lint: spacing-check was not built" >&2; exit 2; }
}
