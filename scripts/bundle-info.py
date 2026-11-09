import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
build = Path(sys.argv[2])
app = build / "TrueWorldTimeProbe.app/Contents"
widget = app / "PlugIns/TrueWorldTimeWidget.appex/Contents"
common = {"CFBundleDevelopmentRegion": "zh_CN", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": "0.4", "CFBundleVersion": "4", "LSMinimumSystemVersion": "15.0", "CFBundleSupportedPlatforms": ["MacOSX"]}
host = dict(common, CFBundleIdentifier="io.xiaonan.TrueWorldTimeProbe", CFBundleExecutable="TrueWorldTimeProbe", CFBundleName="TrueWorldTimeProbe", CFBundleDisplayName="真世界时验证", CFBundlePackageType="APPL", NSPrincipalClass="NSApplication", ProbeEvidenceDirectory=str(root / "evidence"))
extension = dict(common, CFBundleIdentifier="io.xiaonan.TrueWorldTimeProbe.Widget", CFBundleExecutable="TrueWorldTimeWidget", CFBundleName="真世界时验证", CFBundleDisplayName="真世界时验证", CFBundlePackageType="XPC!", NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}, NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
for path, content in [(app / "Info.plist", host), (widget / "Info.plist", extension)]:
    path.write_bytes(plistlib.dumps(content))
(app / "PkgInfo").write_bytes(b"APPL????")
(widget / "PkgInfo").write_bytes(b"XPC!????")
