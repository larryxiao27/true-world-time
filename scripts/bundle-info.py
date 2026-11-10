import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
version = (root / "VERSION").read_text().strip()
build = Path(sys.argv[2])
app = build / "TrueWorldTimeProbe.app/Contents"
widget = app / "PlugIns/TrueWorldTimeWidget.appex/Contents"
common = {"CFBundleDevelopmentRegion": "zh-Hans", "CFBundleLocalizations": ["zh-Hans", "en"], "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": version, "CFBundleVersion": "110", "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "15.0", "CFBundleSupportedPlatforms": ["MacOSX"]}
# Keep the existing on-disk bundle path for upgrades. Finder displays the
# localized name from Resources/*/InfoPlist.strings.
host = dict(common, CFBundleIdentifier="io.xiaonan.TrueWorldTimeProbe", CFBundleExecutable="TrueWorldTime", CFBundleName="TrueWorldTimeProbe", CFBundleDisplayName="TrueWorldTimeProbe", CFBundlePackageType="APPL", NSPrincipalClass="NSApplication", LSUIElement=True)
extension = dict(common, CFBundleIdentifier="io.xiaonan.TrueWorldTimeProbe.Widget", CFBundleExecutable="TrueWorldTimeWidget", CFBundleName="我的时区", CFBundleDisplayName="我的时区", CFBundlePackageType="XPC!", NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}, NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
for path, content in [(app / "Info.plist", host), (widget / "Info.plist", extension)]:
    path.write_bytes(plistlib.dumps(content))
(app / "PkgInfo").write_bytes(b"APPL????")
(widget / "PkgInfo").write_bytes(b"XPC!????")
