"""Reject the wrong product/key/version and feed rollback before feed signing."""
import plistlib
import runpy
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
validate = runpy.run_path(str(root / "scripts/check-update-archive.py"))["validate"]
config = plistlib.loads((root / "Sources/App/Info.plist").read_bytes())
key = config["SUPublicEDKey"]

with tempfile.TemporaryDirectory(prefix="mntfs-update-tests-") as directory:
    archive = Path(directory) / "MNtfs-0.1.2.zip"
    app = dict(config, CFBundleIdentifier="com.fastntfs.FastNTFS",
               CFBundleShortVersionString="0.1.2", CFBundleVersion="3")
    extension = dict(CFBundleIdentifier="com.fastntfs.FastNTFS.FSModule",
                     CFBundleShortVersionString="0.1.2", CFBundleVersion="3")

    def write(a=app, e=extension):
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("MNtfs.app/Contents/Info.plist", plistlib.dumps(a))
            z.writestr("MNtfs.app/Contents/Extensions/FastNTFSFSModule.appex/Contents/Info.plist",
                       plistlib.dumps(e))

    def rejected(a=app, e=extension, version="0.1.2", public_key=key, feed=None):
        write(a, e)
        try:
            validate(archive, version, public_key, feed)
        except ValueError:
            return
        raise AssertionError("unsafe update archive accepted")

    write()
    assert validate(archive, "0.1.2", key) == 3
    rejected(a=dict(app, CFBundleIdentifier="com.maclife.mfinder"))
    rejected(e=dict(extension, CFBundleIdentifier="other.driver"))
    rejected(e=dict(extension, CFBundleVersion="2"))
    rejected(e=dict(extension, CFBundleShortVersionString="0.1.1"))
    rejected(a=dict(app, SUPublicEDKey="wrong-key"))
    rejected(public_key="wrong-key")
    rejected(a=dict(app, SURequireSignedFeed=False))
    rejected(a=dict(app, SUVerifyUpdateBeforeExtraction=False))
    rejected(a=dict(app, SUAllowsAutomaticUpdates=True))
    rejected(a=dict(app, SUAutomaticallyUpdate=True))
    rejected(a=dict(app, SUFeedURL="http://example.com/unsigned.xml"))
    rejected(version="../escape")
    rejected(version="0.1.1")
    feed = Path(directory) / "appcast.xml"
    for build in ["3", "4", "0", "invalid"]:
        feed.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                        f'<channel><item><sparkle:version>{build}</sparkle:version></item></channel></rss>')
        rejected(feed=feed)
    feed.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                    '<channel><item><sparkle:version>2</sparkle:version></item></channel></rss>')
    write()
    assert validate(archive, "0.1.2", key, feed) == 3
print("Update archive identity, signature policy, and rollback tests passed")
