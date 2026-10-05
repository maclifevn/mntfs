#!/bin/bash
# Prepare signed Pages files locally. This script never publishes a release.
set -euo pipefail
TASK_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
VERSION="${1:?usage: build-update-feed.sh VERSION ZIP NOTES OUTPUT_DIR [--bootstrap]}"
ZIP="${2:?missing update ZIP}"
NOTES="${3:?missing release notes}"
OUTPUT="${4:?missing output directory}"
BOOTSTRAP="${5:-}"
[[ -z "$BOOTSTRAP" || "$BOOTSTRAP" == "--bootstrap" ]] || { echo "Unknown option: $BOOTSTRAP" >&2; exit 1; }
BIN="${MNTFS_SPARKLE_BIN:-$TASK_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
ACCOUNT="${MNTFS_SPARKLE_ACCOUNT:-com.fastntfs.FastNTFS}"
FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Sources/App/Info.plist)
PAGES_BASE="${FEED%/appcast.xml}/"
CURRENT_FEED="${MNTFS_CURRENT_FEED_URL:-$FEED}"
REPOSITORY="${MNTFS_RELEASE_REPOSITORY:-maclifevn/mntfs}"
for tool in generate_appcast sign_update generate_keys; do
    [ -x "$BIN/$tool" ] || { echo "Missing Sparkle tool: $BIN/$tool. Resolve packages first (see RELEASING.md)." >&2; exit 1; }
done
[ -f "$ZIP" ] && [ -f "$NOTES" ] || { echo "Missing ZIP or release notes" >&2; exit 1; }
PUBLIC_KEY=$("$BIN/generate_keys" --account "$ACCOUNT" -p)
python3 scripts/check-update-archive.py "$ZIP" "$VERSION" "$PUBLIC_KEY" >/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mntfs-appcast.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ARCHIVES="$WORK/archives"
PAGES="$WORK/pages/updates"
mkdir -p "$ARCHIVES" "$PAGES" "$WORK/app"
ditto -x -k "$ZIP" "$WORK/app"
if [ "${MNTFS_ALLOW_UNNOTARIZED_TEST_ARCHIVE:-0}" != "1" ]; then
    codesign --verify --deep --strict "$WORK/app/MNtfs.app"
    xcrun stapler validate "$WORK/app/MNtfs.app"
else
    echo "TEST ONLY: skipping Developer ID / notarization validation" >&2
fi

# An outage must not silently reset history or allow a lower build to ship.
# Bootstrap is explicit and only accepts an HTTP 404 (not TLS/network errors).
if [ -n "${MNTFS_PREVIOUS_APPCAST:-}" ]; then
    ditto "$MNTFS_PREVIOUS_APPCAST" "$ARCHIVES/appcast.xml"
else
    STATUS=$(curl --silent --show-error --location --connect-timeout 15 --max-time 60 \
        --output "$WORK/current.xml" --write-out '%{http_code}' "$CURRENT_FEED")
    if [ "$STATUS" = "200" ]; then
        mv "$WORK/current.xml" "$ARCHIVES/appcast.xml"
    elif [ "$STATUS" = "404" ] && [ "$BOOTSTRAP" = "--bootstrap" ]; then
        echo "Creating the first signed appcast."
    else
        echo "Cannot reuse production appcast (HTTP $STATUS). First release requires --bootstrap and HTTP 404." >&2
        exit 1
    fi
fi
if [ -f "$ARCHIVES/appcast.xml" ]; then
    "$BIN/sign_update" --verify --account "$ACCOUNT" "$ARCHIVES/appcast.xml"
    python3 scripts/check-update-archive.py "$ZIP" "$VERSION" "$PUBLIC_KEY" "$ARCHIVES/appcast.xml" >/dev/null
    /usr/bin/ruby -r rexml/document -e '
      doc = REXML::Document.new(File.read(ARGV[0]))
      REXML::XPath.each(doc, "//*[local-name()=\"releaseNotesLink\"]") do |node|
        signature = node.attributes["sparkle:edSignature"].to_s
        abort("unsigned retained release notes") if signature.empty?
        puts [node.text.to_s.strip, signature].join("\t")
      end
    ' "$ARCHIVES/appcast.xml" > "$WORK/notes.tsv"
    while IFS=$'\t' read -r url signature; do
        name="${url##*/}"
        [[ "$url" == "$PAGES_BASE"* && "$name" =~ ^MNtfs-[0-9.]+\.(md|html|txt)$ ]] || {
            echo "Unexpected retained notes URL: $url" >&2; exit 1;
        }
        if [ -n "${MNTFS_PREVIOUS_NOTES_DIR:-}" ]; then
            ditto "$MNTFS_PREVIOUS_NOTES_DIR/$name" "$PAGES/$name"
        else
            curl --fail --silent --show-error --location --connect-timeout 15 --max-time 60 \
                "$url" -o "$PAGES/$name"
        fi
        "$BIN/sign_update" --verify --account "$ACCOUNT" "$PAGES/$name" "$signature"
    done < "$WORK/notes.tsv"
fi

NAME="MNtfs-$VERSION"
ditto "$ZIP" "$ARCHIVES/$NAME.zip"
ditto "$NOTES" "$ARCHIVES/$NAME.md"
"$BIN/generate_appcast" --account "$ACCOUNT" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
    --release-notes-url-prefix "$PAGES_BASE" --link "${PAGES_BASE%updates/}" \
    --maximum-versions 5 --maximum-deltas 0 --phased-rollout-interval 86400 \
    --disable-signing-warning "$ARCHIVES"
ditto "$ARCHIVES/appcast.xml" "$PAGES/appcast.xml"
ditto "$ARCHIVES/$NAME.md" "$PAGES/$NAME.md"
MNTFS_SPARKLE_ACCOUNT="$ACCOUNT" bash scripts/verify-update-feed.sh \
    "$PAGES/appcast.xml" "$ARCHIVES/$NAME.zip" "$PAGES/$NAME.md" "$BIN/sign_update"
# Replace output only after all verification passes. Do not delete older notes:
# cached appcasts on clients can still reference them.
mkdir -p "$OUTPUT/updates"
ditto "$PAGES" "$OUTPUT/updates"
echo "Signed feed ready: $OUTPUT/updates/appcast.xml"
