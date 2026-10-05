#!/bin/bash
# Verify feed/archive/notes, then ensure tampering with each is rejected.
set -euo pipefail
APPCAST="${1:?missing appcast}"
ZIP="${2:?missing archive}"
NOTES="${3:?missing release notes}"
SIGN="${4:?missing sign_update}"
ACCOUNT="${MNTFS_SPARKLE_ACCOUNT:-com.fastntfs.FastNTFS}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mntfs-signatures.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
/usr/bin/ruby -r rexml/document -r uri -e '
  doc = REXML::Document.new(File.read(ARGV[0]))
  enclosure = REXML::XPath.match(doc, "//*[local-name()=\"enclosure\"]").find do |n|
    File.basename(URI(n.attributes["url"]).path) == File.basename(ARGV[1])
  end
  abort("archive missing from appcast") unless enclosure
  notes = REXML::XPath.first(enclosure.parent, "*[local-name()=\"releaseNotesLink\"]")
  abort("release notes missing") unless notes && File.basename(URI(notes.text.strip).path) == File.basename(ARGV[2])
  abort("archive length mismatch") unless enclosure.attributes["length"].to_i == File.size(ARGV[1])
  [enclosure, notes].each do |node|
    signature = node.attributes["sparkle:edSignature"].to_s
    abort("Ed25519 signature missing") if signature.empty?
    puts signature
  end
' "$APPCAST" "$ZIP" "$NOTES" > "$WORK/signatures"
ZIP_SIGNATURE=$(sed -n '1p' "$WORK/signatures")
NOTES_SIGNATURE=$(sed -n '2p' "$WORK/signatures")
"$SIGN" --verify --account "$ACCOUNT" "$APPCAST"
"$SIGN" --verify --account "$ACCOUNT" "$ZIP" "$ZIP_SIGNATURE"
"$SIGN" --verify --account "$ACCOUNT" "$NOTES" "$NOTES_SIGNATURE"
ditto "$APPCAST" "$WORK/appcast.xml"
ditto "$ZIP" "$WORK/archive.zip"
ditto "$NOTES" "$WORK/notes.md"
# Alter signed XML content, preserving the embedded signature comment.
/usr/bin/ruby -e '
  s = File.binread(ARGV[0])
  abort("appcast tamper marker missing") unless s.sub!("MNtfs", "MNtfx")
  File.binwrite(ARGV[0], s)
' "$WORK/appcast.xml"
printf 'x' >> "$WORK/archive.zip"
printf 'x' >> "$WORK/notes.md"
if "$SIGN" --verify --account "$ACCOUNT" "$WORK/appcast.xml"; then
    echo "Tampered feed accepted" >&2; exit 1
fi
if "$SIGN" --verify --account "$ACCOUNT" "$WORK/archive.zip" "$ZIP_SIGNATURE"; then
    echo "Tampered ZIP accepted" >&2; exit 1
fi
if "$SIGN" --verify --account "$ACCOUNT" "$WORK/notes.md" "$NOTES_SIGNATURE"; then
    echo "Tampered notes accepted" >&2; exit 1
fi
echo "Sparkle signatures and tamper rejection passed"
