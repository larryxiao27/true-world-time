"""Generate a dependency-free, standard two-target Xcode probe project."""
import hashlib
import json
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text().strip()
objects = {}

def oid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def add(object_key, isa, **fields):
    key = oid(object_key)
    objects[key] = dict(isa=isa, **fields)
    return key

def plist_value(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(str(k)) + " = " + plist_value(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(plist_value(v, level) for v in value) + ")"
    return json.dumps(str(value), ensure_ascii=False)

sources = ["Sources/ClockCore/ClockCore.swift", "App/TrueWorldTimeProbe.swift", "Widget/TrueWorldTimeWidget.swift", "AppSupport/LoginItemController.swift", "AppSupport/SystemResources.swift"]
file_ids = {path: add(path, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path, sourceTree="<group>") for path in sources}
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="TrueWorldTimeProbe.app", sourceTree="BUILT_PRODUCTS_DIR")
widget_product = add("widget-product", "PBXFileReference", explicitFileType="wrapper.app-extension", path="TrueWorldTimeWidget.appex", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[app_product, widget_product], name="Products", sourceTree="<group>")
localized_files = [add("strings-" + language, "PBXFileReference", lastKnownFileType="text.plist.strings", name=language, path="Resources/" + language + ".lproj/InfoPlist.strings", sourceTree="<group>") for language in ["zh-Hans", "en"]]
localized_group = add("localized-strings", "PBXVariantGroup", children=localized_files, name="InfoPlist.strings", sourceTree="<group>")
main_group = add("main-group", "PBXGroup", children=list(file_ids.values()) + [localized_group, products], sourceTree="<group>")

common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "ARCHS": "arm64", "SWIFT_VERSION": "6.0", "CLANG_ENABLE_MODULES": "YES", "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES", "CURRENT_PROJECT_VERSION": "100", "MARKETING_VERSION": version, "SUPPORTED_PLATFORMS": "macosx", "GENERATE_INFOPLIST_FILE": "NO"}
def configs(name, settings):
    ids = []
    for configuration in ["Debug", "Release"]:
        flags = dict(settings, SWIFT_OPTIMIZATION_LEVEL="-Onone" if configuration == "Debug" else "-O")
        ids.append(add(name + configuration, "XCBuildConfiguration", name=configuration, buildSettings=flags))
    return add(name + "-configs", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

widget_sources = add("widget-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[add("widget-" + p, "PBXBuildFile", fileRef=file_ids[p]) for p in [sources[0], sources[2]]], runOnlyForDeploymentPostprocessing=0)
widget_frameworks = add("widget-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
widget_settings = dict(common, PRODUCT_NAME="TrueWorldTimeWidget", PRODUCT_BUNDLE_IDENTIFIER="io.xiaonan.TrueWorldTimeProbe.Widget", INFOPLIST_FILE="Config/Widget-Info.plist", CODE_SIGN_ENTITLEMENTS="Config/Widget.entitlements", ENABLE_APP_SANDBOX="YES", APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"])
widget_target = add("widget-target", "PBXNativeTarget", name="TrueWorldTimeWidget", buildConfigurationList=configs("widget", widget_settings), buildPhases=[widget_sources, widget_frameworks], buildRules=[], dependencies=[], productName="TrueWorldTimeWidget", productReference=widget_product, productType="com.apple.product-type.app-extension")
proxy = add("widget-proxy", "PBXContainerItemProxy", containerPortal=oid("project"), proxyType=1, remoteGlobalIDString=widget_target, remoteInfo="TrueWorldTimeWidget")
dependency = add("widget-dependency", "PBXTargetDependency", target=widget_target, targetProxy=proxy)
embedded = add("widget-copy", "PBXBuildFile", fileRef=widget_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = add("embed-widgets", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13, files=[embedded], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
app_sources = add("app-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[add("app-" + p, "PBXBuildFile", fileRef=file_ids[p]) for p in [sources[0], sources[1]] + sources[3:]], runOnlyForDeploymentPostprocessing=0)
app_frameworks = add("app-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
app_resources = add("app-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[add("strings-build", "PBXBuildFile", fileRef=localized_group)], runOnlyForDeploymentPostprocessing=0)
app_settings = dict(common, PRODUCT_NAME="TrueWorldTimeProbe", EXECUTABLE_NAME="TrueWorldTime", PRODUCT_MODULE_NAME="TrueWorldTime", PRODUCT_BUNDLE_IDENTIFIER="io.xiaonan.TrueWorldTimeProbe", INFOPLIST_FILE="Config/App-Info.plist", ENABLE_APP_SANDBOX="NO", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"], COMBINE_HIDPI_IMAGES="YES")
app_target = add("app-target", "PBXNativeTarget", name="TrueWorldTimeProbe", buildConfigurationList=configs("app", app_settings), buildPhases=[app_sources, app_frameworks, app_resources, embed_phase], buildRules=[], dependencies=[dependency], productName="TrueWorldTimeProbe", productReference=app_product, productType="com.apple.product-type.application")
project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "2620", "BuildIndependentTargetsInParallel": "YES"}, buildConfigurationList=configs("project", common), compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, widget_target])
bundle = root / "TrueWorldTimeProbe.xcodeproj"
bundle.mkdir(exist_ok=True)
(bundle / "project.pbxproj").write_text("// !$*UTF8*$!\n" + plist_value({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n")
scheme_dir = bundle / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="TrueWorldTimeProbe.app" BlueprintName="TrueWorldTimeProbe" ReferencedContainer="container:TrueWorldTimeProbe.xcodeproj"/>'
(scheme_dir / "TrueWorldTimeProbe.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
info = {"CFBundleDevelopmentRegion": "zh-Hans", "CFBundleLocalizations": ["zh-Hans", "en"], "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)", "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)", "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)"}
app_info = dict(info, CFBundleDisplayName="TrueWorldTimeProbe", CFBundlePackageType="APPL", NSPrincipalClass="NSApplication", LSUIElement=True)
widget_info = dict(info, CFBundleDisplayName="真世界时", CFBundlePackageType="XPC!", NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}, NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
for name, value in [("App-Info.plist", app_info), ("Widget-Info.plist", widget_info)]:
    (root / "Config" / name).write_bytes(plistlib.dumps(value))
print(bundle)
