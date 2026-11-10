"""Check product branding, upgrade identity, archives and checksums before release."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text().strip()
app = Path(sys.argv[1])
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
host = plistlib.loads((app / "Contents/Info.plist").read_bytes())
widget = app / "Contents/PlugIns/TrueWorldTimeWidget.appex"
extension = plistlib.loads((widget / "Contents/Info.plist").read_bytes())
assert host["CFBundleShortVersionString"] == extension["CFBundleShortVersionString"] == version
assert host["CFBundleIdentifier"] == "io.xiaonan.TrueWorldTimeProbe"
assert extension["CFBundleIdentifier"] == "io.xiaonan.TrueWorldTimeProbe.Widget"
assert host["CFBundleExecutable"] == "TrueWorldTime" and host["LSUIElement"] is True
assert "ProbeEvidenceDirectory" not in host
for language in ("en", "zh-Hans"):
    text = (app / f"Contents/Resources/{language}.lproj/InfoPlist.strings").read_text()
    assert '"CFBundleDisplayName" = "真世界时";' in text
for binary in (app / "Contents/MacOS/TrueWorldTime", widget / "Contents/MacOS/TrueWorldTimeWidget"):
    data = binary.read_bytes()
    for obsolete in ("真世界时验证", "技术验证", "这是验证组件", "注入网络失败", "抓取时真值", "动态文本"):
        assert obsolete.encode() not in data, (binary.name, obsolete)
archive = root / f"dist/TrueWorldTime-{version}.zip"
with zipfile.ZipFile(archive) as contents:
    assert contents.testzip() is None
    packaged_host = plistlib.loads(contents.read("TrueWorldTimeProbe.app/Contents/Info.plist"))
    assert packaged_host == host
    assert contents.read("TrueWorldTimeProbe.app/Contents/MacOS/TrueWorldTime") == (app / "Contents/MacOS/TrueWorldTime").read_bytes()
assets = [root / f"dist/TrueWorldTime-{version}.dmg", archive]
checksums = [(path.name, hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size) for path in assets]
(root / "dist/SHA256SUMS.txt").write_text("".join(f"{digest}  {name}\n" for name, digest, _ in checksums))
report = {"version": version, "branding": "passed", "signatureIntegrity": "passed", "upgradeIdentifiers": "preserved", "assets": [{"name": name, "sha256": digest, "bytes": size} for name, digest, size in checksums], "notarized": False}
(root / "evidence/release-audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
