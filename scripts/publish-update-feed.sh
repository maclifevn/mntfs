#!/bin/bash
# Publish an already verified release feed after its archive is downloadable.
set -euo pipefail
TASK_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
VERSION="${1:?usage: publish-update-feed.sh VERSION [DIST_DIR]}"
DIST="${2:-dist}"
REPOSITORY="${MNTFS_RELEASE_REPOSITORY:-maclifevn/mntfs}"
BIN="${MNTFS_SPARKLE_BIN:-$TASK_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
ACCOUNT="${MNTFS_SPARKLE_ACCOUNT:-com.fastntfs.FastNTFS}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "Invalid version" >&2; exit 1; }
ZIP="$DIST/MNtfs-$VERSION.zip"
FEED="$DIST/updates/appcast.xml"
NOTES="$DIST/updates/MNtfs-$VERSION.md"
PUBLIC_KEY=$("$BIN/generate_keys" --account "$ACCOUNT" -p)
python3 scripts/check-update-archive.py "$ZIP" "$VERSION" "$PUBLIC_KEY" >/dev/null
MNTFS_SPARKLE_ACCOUNT="$ACCOUNT" bash scripts/verify-update-feed.sh \
    "$FEED" "$ZIP" "$NOTES" "$BIN/sign_update"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mntfs-pages.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
gh release view "v$VERSION" --repo "$REPOSITORY" --json isDraft,assets > "$WORK/release.json"
python3 - "$WORK/release.json" "$ZIP" "$REPOSITORY" "$VERSION" "$FEED" <<'PY'
import hashlib, json, sys, xml.etree.ElementTree as ET
from pathlib import Path
metadata, archive, repository, version, feed = sys.argv[1:]
release = json.loads(Path(metadata).read_text())
if release['isDraft']:
    sys.exit('Publish the GitHub release before its feed.')
name = f'MNtfs-{version}.zip'
url = f'https://github.com/{repository}/releases/download/v{version}/{name}'
asset = next((a for a in release['assets'] if a['name'] == name), None)
digest = 'sha256:' + hashlib.sha256(Path(archive).read_bytes()).hexdigest()
if not asset or asset.get('state') != 'uploaded' or asset.get('digest') != digest or asset['url'] != url:
    sys.exit('Published archive is missing or differs from the signed local ZIP.')
if not any(e.get('url') == url for e in ET.parse(feed).findall('.//enclosure')):
    sys.exit('Appcast does not point to the published archive.')
PY

# Work in an isolated temporary checkout, leaving the app source branch alone.
REMOTE="https://github.com/$REPOSITORY.git"
git init -q "$WORK/pages"
git -C "$WORK/pages" remote add origin "$REMOTE"
if [ -n "$(git ls-remote --heads "$REMOTE" refs/heads/gh-pages)" ]; then
    git -C "$WORK/pages" fetch -q origin gh-pages
    git -C "$WORK/pages" checkout -q -b gh-pages FETCH_HEAD
    if [ -f "$WORK/pages/updates/appcast.xml" ]; then
        "$BIN/sign_update" --verify --account "$ACCOUNT" "$WORK/pages/updates/appcast.xml"
        python3 scripts/check-update-archive.py "$ZIP" "$VERSION" "$PUBLIC_KEY" \
            "$WORK/pages/updates/appcast.xml" >/dev/null
    fi
else
    git -C "$WORK/pages" checkout -q --orphan gh-pages
fi
mkdir -p "$WORK/pages/updates"
# Keep old notes for clients using a cached appcast.
ditto "$DIST/updates" "$WORK/pages/updates"
touch "$WORK/pages/.nojekyll"
if [ ! -f "$WORK/pages/index.html" ]; then
    cat > "$WORK/pages/index.html" <<HTML
<!doctype html>
<html lang="en"><meta charset="utf-8"><title>MNtfs updates</title>
<p><a href="https://github.com/$REPOSITORY/releases/latest">Download MNtfs</a></p>
<p><a href="updates/appcast.xml">Signed Sparkle update feed</a></p></html>
HTML
fi
gh api user --jq '{login,id,name}' > "$WORK/user.json"
AUTHOR_NAME=$(python3 -c 'import json,sys; u=json.load(open(sys.argv[1])); print(u["name"] or u["login"])' "$WORK/user.json")
AUTHOR_EMAIL=$(python3 -c 'import json,sys; u=json.load(open(sys.argv[1])); print(str(u["id"])+"+"+u["login"]+"@users.noreply.github.com")' "$WORK/user.json")
git -C "$WORK/pages" add .nojekyll index.html updates
git -C "$WORK/pages" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
    commit -q -m "Publish signed MNtfs $VERSION update feed"
git -C "$WORK/pages" push origin gh-pages
echo "Published feed to gh-pages. Enable GitHub Pages from gh-pages / once; see RELEASING.md."
