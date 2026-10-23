#!/usr/bin/env python3
"""Regenerate the checked-in project using only Python's standard library."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def ident(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
def add(key, value):
    objects[ident(key)] = value
    return ident(key)
def ref(key): return ident(key)
def seq(values): return '(' + ', '.join(values) + (',' if values else '') + ')'

app_files = sorted((ROOT / 'MassiveX').rglob('*.swift')) + sorted((ROOT / 'MassiveX').rglob('*.c')) + sorted((ROOT / 'Vendor').rglob('*.c'))
test_files = sorted((ROOT / 'MassiveXTests').glob('*.swift'))
for path in app_files + test_files:
    relative = path.relative_to(ROOT).as_posix()
    file_type = 'sourcecode.c.c' if path.suffix == '.c' else 'sourcecode.swift'
    add(relative, f'{{isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{relative}"; sourceTree = SOURCE_ROOT; }}')
    add('build:' + relative, f'{{isa = PBXBuildFile; fileRef = {ref(relative)}; }}')
add('assets', '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = MassiveX/Assets.xcassets; sourceTree = SOURCE_ROOT; }')
add('localizations', '{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = MassiveX/Localization/Localizable.xcstrings; sourceTree = SOURCE_ROOT; }')
add('privacy-localizations', '{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = MassiveX/Localization/InfoPlist.xcstrings; sourceTree = SOURCE_ROOT; }')
add('privacy-localizations-build', f'{{isa = PBXBuildFile; fileRef = {ref("privacy-localizations")}; }}')
add('localizations-build', f'{{isa = PBXBuildFile; fileRef = {ref("localizations")}; }}')
add('assets-build', f'{{isa = PBXBuildFile; fileRef = {ref("assets")}; }}')
add('privacy-manifest', '{isa = PBXFileReference; lastKnownFileType = text.xml; path = MassiveX/PrivacyInfo.xcprivacy; sourceTree = SOURCE_ROOT; }')
add('privacy-manifest-build', f'{{isa = PBXBuildFile; fileRef = {ref("privacy-manifest")}; }}')
add('app-product', '{isa = PBXFileReference; explicitFileType = wrapper.application; path = MassiveX.app; sourceTree = BUILT_PRODUCTS_DIR; }')
add('tests-product', '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = MassiveXTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }')
add('products', f'{{isa = PBXGroup; name = Products; children = {seq([ref("app-product"), ref("tests-product")])}; sourceTree = "<group>"; }}')
add('main', f'{{isa = PBXGroup; children = {seq([ref(p.relative_to(ROOT).as_posix()) for p in app_files + test_files] + [ref("assets"), ref("localizations"), ref("privacy-localizations"), ref("privacy-manifest"), ref("products")])}; sourceTree = "<group>"; }}')
for target, files in [('app', app_files), ('tests', test_files)]:
    for phase, isa, contents in [('sources', 'PBXSourcesBuildPhase', [ref('build:' + p.relative_to(ROOT).as_posix()) for p in files]), ('frameworks', 'PBXFrameworksBuildPhase', []), ('resources', 'PBXResourcesBuildPhase', [ref('assets-build'), ref('localizations-build'), ref('privacy-localizations-build'), ref('privacy-manifest-build')] if target == 'app' else [])]:
        add(target + phase, f'{{isa = {isa}; buildActionMask = 2147483647; files = {seq(contents)}; runOnlyForDeploymentPostprocessing = 0; }}')
add('proxy', f'{{isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("app")}; remoteInfo = MassiveX; }}')
add('dependency', f'{{isa = PBXTargetDependency; target = {ref("app")}; targetProxy = {ref("proxy")}; }}')
for target, name, product_type in [('app', 'MassiveX', 'application'), ('tests', 'MassiveXTests', 'bundle.unit-test')]:
    add(target, f'{{isa = PBXNativeTarget; buildConfigurationList = {ref(target + "configs")}; buildPhases = {seq([ref(target + p) for p in ["sources", "frameworks", "resources"]])}; buildRules = (); dependencies = {seq([ref("dependency")] if target != "app" else [])}; name = {name}; productName = {name}; productReference = {ref(target + "-product")}; productType = "com.apple.product-type.{product_type}"; }}')
for scope in ['project', 'app', 'tests']:
    for config in ['Debug', 'Release']:
        settings = {'SWIFT_VERSION': '6.0', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos', 'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'complete'}
        if scope == 'project':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config != 'Release' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if config != 'Release' else 'dwarf-with-dsym', 'ENABLE_TESTABILITY': 'YES' if config != 'Release' else 'NO'})
            if config != 'Release': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        else:
            settings.update({'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.massivex.wallet' + ('.' + scope if scope != 'app' else ''), 'GENERATE_INFOPLIST_FILE': 'YES', 'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'CODE_SIGN_STYLE': 'Automatic', 'MARKETING_VERSION': '0.7.5', 'CURRENT_PROJECT_VERSION': '18'})
            if scope == 'app': settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES': 'MassiveXIcon001 MassiveXIcon002 MassiveXIcon003', 'ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS': 'YES'})
            if scope == 'app': settings.update({'SWIFT_OBJC_BRIDGING_HEADER': 'MassiveX/Core/MassaNative.h', 'GCC_PREPROCESSOR_DEFINITIONS': '$(inherited) BLAKE3_NO_SSE2 BLAKE3_NO_SSE41 BLAKE3_NO_AVX2 BLAKE3_NO_AVX512 BLAKE3_USE_NEON=0'})
            if scope == 'app': settings.update({'INFOPLIST_FILE': 'MassiveX/Info.plist', 'INFOPLIST_KEY_CFBundleDisplayName': 'Massive X', 'INFOPLIST_KEY_NSFaceIDUsageDescription': 'Authenticate to access the selected wallet’s protected key.', 'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES', 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation': 'YES', 'INFOPLIST_KEY_UISupportedInterfaceOrientations': 'UIInterfaceOrientationPortrait', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor'})
            else: settings.update({'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/MassiveX.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MassiveX', 'BUNDLE_LOADER': '$(TEST_HOST)'})
        body = ' '.join(f'{key} = "{value}";' for key, value in settings.items())
        add(scope + config, f'{{isa = XCBuildConfiguration; buildSettings = {{{body}}}; name = {config}; }}')
    add(scope + 'configs', f'{{isa = XCConfigurationList; buildConfigurations = {seq([ref(scope + "Debug"), ref(scope + "Release")])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
add('project', f'{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2710; }}; buildConfigurationList = {ref("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, fr, ru, es, "zh-Hans", de, Base); mainGroup = {ref("main")}; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = {seq([ref("app"), ref("tests")])}; }}')
project = ROOT / 'MassiveX.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{key} = {value};' for key, value in objects.items()) + f'\n}}; rootObject = {ref("project")}; }}\n')
def buildable(target, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(target)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:MassiveX.xcodeproj"/>'
app = buildable('app', 'MassiveX', 'MassiveX.app')
tests = buildable('tests', 'MassiveXTests', 'MassiveXTests.xctest')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{tests}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_path = project / 'xcshareddata/xcschemes/MassiveX.xcscheme'
scheme_path.parent.mkdir(parents=True, exist_ok=True)
scheme_path.write_text(scheme)
