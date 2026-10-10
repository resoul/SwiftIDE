#!/bin/zsh
# Downloads the pinned SwiftFormat and SwiftLint into Tools/Lint/.tools and checks their SHA-256
# before anything is unpacked. Nothing is installed outside this directory. Safe to run again.
#
# To change a version: change both lines below (version and the digest GitHub shows next to the
# release asset), run this script, run `Tools/Lint/lint.sh`, and record the change in
# docs/14_CODE_STYLE_AND_LINTING.md.
set -eu
cd "${0:A:h}"

SWIFTFORMAT_VERSION=0.63.1
SWIFTFORMAT_URL="https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/swiftformat.zip"
SWIFTFORMAT_SHA256=385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb

SWIFTLINT_VERSION=0.65.1
SWIFTLINT_URL="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
SWIFTLINT_SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0

mkdir -p .tools

fetch() {  # name version url sha256 binary
  local name=$1 version=$2 url=$3 sha=$4 binary=$5
  local target=".tools/${name}-${version}"
  if [[ -x "$target/$binary" ]]; then
    echo "$name $version: present"
    return
  fi
  local zip=".tools/${name}-${version}.zip"
  echo "$name $version: downloading $url"
  curl --fail --location --silent --show-error --output "$zip" "$url"
  local actual
  actual=$(shasum -a 256 "$zip" | awk '{print $1}')
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$zip"
    echo "$name: SHA-256 mismatch (expected $sha, got $actual); not unpacked" >&2
    exit 1
  fi
  rm -rf "$target"
  mkdir -p "$target"
  unzip -q -o "$zip" -d "$target"
  rm -f "$zip"
  chmod +x "$target/$binary"
  echo "$name $version: installed"
}

fetch swiftformat "$SWIFTFORMAT_VERSION" "$SWIFTFORMAT_URL" "$SWIFTFORMAT_SHA256" swiftformat
fetch swiftlint "$SWIFTLINT_VERSION" "$SWIFTLINT_URL" "$SWIFTLINT_SHA256" swiftlint

# Stable names for the other scripts.
ln -sfn "swiftformat-${SWIFTFORMAT_VERSION}/swiftformat" .tools/swiftformat
ln -sfn "swiftlint-${SWIFTLINT_VERSION}/swiftlint" .tools/swiftlint
.tools/swiftformat --version
.tools/swiftlint --version
