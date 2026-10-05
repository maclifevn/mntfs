#!/usr/bin/env python3
"""Validate update identity, trust settings, and monotonic build numbers."""
import argparse
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


def validate(archive, version, public_key, previous_feed=None):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise ValueError("release version must be a numeric dotted version")
    with zipfile.ZipFile(archive) as z:
        app = plistlib.loads(z.read("MNtfs.app/Contents/Info.plist"))
        extension = plistlib.loads(z.read(
            "MNtfs.app/Contents/Extensions/FastNTFSFSModule.appex/Contents/Info.plist"))
    if app.get("CFBundleIdentifier") != "com.fastntfs.FastNTFS":
        raise ValueError("wrong host bundle identifier")
    if extension.get("CFBundleIdentifier") != "com.fastntfs.FastNTFS.FSModule":
        raise ValueError("wrong FSKit extension bundle identifier")
    build = str(app.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive integer")
    for bundle in [app, extension]:
        if bundle.get("CFBundleShortVersionString") != version or str(bundle.get("CFBundleVersion")) != build:
            raise ValueError("host/extension version or build mismatch")
    source = plistlib.loads((Path(__file__).resolve().parent.parent / "Sources/App/Info.plist").read_bytes())
    if app.get("SUPublicEDKey") != public_key or public_key != source["SUPublicEDKey"]:
        raise ValueError("Keychain signing key does not match the app's embedded public key")
    for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]:
        if app.get(key) is not True:
            raise ValueError(f"archive must enable {key}")
    for key in ["SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate"]:
        if app.get(key) is not False:
            raise ValueError(f"driver updates require an interactive install ({key})")
    if app.get("SUFeedURL") != source["SUFeedURL"]:
        raise ValueError("archive feed URL differs from the production configuration")
    if previous_feed:
        ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        builds = [item.text for item in ET.parse(previous_feed).findall(".//s:version", ns)]
        if not builds or any(not re.fullmatch(r"[1-9][0-9]*", b or "") for b in builds):
            raise ValueError("previous feed contains invalid build numbers")
        if int(build) <= max(map(int, builds)):
            raise ValueError("new CFBundleVersion must be greater than every published build")
    return int(build)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("version")
    parser.add_argument("public_key")
    parser.add_argument("previous_feed", nargs="?")
    args = parser.parse_args()
    try:
        print(validate(args.archive, args.version, args.public_key, args.previous_feed))
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, ET.ParseError, plistlib.InvalidFileException) as error:
        sys.exit(f"Update archive rejected: {error}")
