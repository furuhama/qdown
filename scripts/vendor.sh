#!/bin/bash
# Re-fetch the pinned JavaScript libraries used by Qdown at build time.
# The app never accesses the network at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Qdown/Resources/vendor"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qdown-vendor.XXXXXX")"
CACHE="$(mktemp -d "${TMPDIR:-/tmp}/qdown-npm-cache.XXXXXX")"
trap 'rm -rf "$WORK" "$CACHE"' EXIT

MARKED_VERSION="12.0.2"
HIGHLIGHT_VERSION="11.11.1"
MERMAID_VERSION="10.9.5"

mkdir -p "$VENDOR/highlight-languages"
cd "$WORK"
export npm_config_cache="$CACHE"

echo "==> Fetching marked@$MARKED_VERSION"
npm pack "marked@$MARKED_VERSION" --silent
mkdir marked && tar -xzf "marked-$MARKED_VERSION.tgz" -C marked
cp "marked/package/marked.min.js" "$VENDOR/marked.min.js"
cp "marked/package/LICENSE.md" "$VENDOR/marked.LICENSE.md"

echo "==> Fetching mermaid@$MERMAID_VERSION"
npm pack "mermaid@$MERMAID_VERSION" --silent
mkdir mermaid && tar -xzf "mermaid-$MERMAID_VERSION.tgz" -C mermaid
cp "mermaid/package/dist/mermaid.min.js" "$VENDOR/mermaid.min.js"
cp "mermaid/package/LICENSE" "$VENDOR/mermaid.LICENSE"

echo "==> Fetching highlight.js CDN assets @$HIGHLIGHT_VERSION"
npm pack "@highlightjs/cdn-assets@$HIGHLIGHT_VERSION" --silent
mkdir highlight && tar -xzf "highlightjs-cdn-assets-$HIGHLIGHT_VERSION.tgz" -C highlight
cp "highlight/package/highlight.min.js" "$VENDOR/highlight.min.js"
cp "highlight/package/LICENSE" "$VENDOR/highlight.LICENSE"
for language in dockerfile powershell dart elixir erlang haskell scala clojure groovy \
                julia ocaml protobuf nix cmake dos http properties; do
  cp "highlight/package/languages/$language.min.js" "$VENDOR/highlight-languages/"
done

echo
echo "Vendored files:"
find "$VENDOR" -type f | sort
echo
echo "quiet-light.css is the canonical theme file and is intentionally NOT fetched."
echo "Keep it byte-identical to the supplied quiet-light.css."
