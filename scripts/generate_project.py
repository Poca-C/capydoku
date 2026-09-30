"""Reproducible dependency-free Xcode project. Run after adding app/UI test files."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(s): return json.dumps(str(s))
def obj(name, body):
    key = ident(name); objects[key] = body; return key
def arr(values): return '(' + ', '.join(values) + (',' if values else '') + ')'

# The original scheme keeps its installed Demo identity. These additional
# configurations are isolated candidates, not publisher-issued production IDs.
configuration_files = {
    'Debug': 'InternalDemo.xcconfig',
    'Release': 'InternalDemo.xcconfig',
    'TestFlight': 'Testing.xcconfig',
    'Staging': 'Staging.xcconfig',
    'Production': 'Production.xcconfig',
}
configuration_refs = {}
for path in sorted((ROOT/'Configurations').glob('*.xcconfig')):
    rel = str(path.relative_to(ROOT))
    configuration_refs[path.name] = obj('ref:'+rel,
        f'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = {q(rel)}; sourceTree = SOURCE_ROOT;')
configurations_group = obj('configurations-group',
    f'isa = PBXGroup; children = {arr(list(configuration_refs.values()))}; name = Configurations; sourceTree = "<group>";')

app_sources = sorted((ROOT/'App').rglob('*.swift'))
ui_sources = sorted((ROOT/'UITests').glob('*.swift'))
unit_sources = sorted((ROOT/'AppTests').glob('*.swift'))
unit_resources = sorted((ROOT/'Tests/Fixtures').glob('*.json'))
resources = sorted((ROOT/'Resources').glob('*.json'))
resources += sorted((ROOT/'App/Resources/Localization').glob('*.json'))
resources += [ROOT/'App/PrivacyInfo.xcprivacy']
asset = ROOT/'App/Resources/Assets.xcassets'
if asset.exists(): resources.append(asset)
audio = ROOT/'App/Resources/Audio'
if audio.exists(): resources += sorted(p for p in audio.iterdir() if p.suffix.lower() in {'.wav', '.mp3', '.m4a', '.aif', '.aiff', '.caf'})

def files(paths, phase):
    refs=[]; builds=[]
    for path in paths:
        rel=str(path.relative_to(ROOT))
        typ={'.swift':'sourcecode.swift','.json':'text.json','.xcassets':'folder.assetcatalog', '.wav':'audio.wav', '.mp3':'audio.mp3', '.m4a':'audio.mp4', '.aif':'audio.aiff', '.aiff':'audio.aiff', '.caf':'file', '.xcprivacy':'text.xml'}.get(path.suffix,'text')
        ref=obj('ref:'+rel, f'isa = PBXFileReference; lastKnownFileType = {q(typ)}; path = {q(rel)}; sourceTree = SOURCE_ROOT;')
        build=obj('build:'+phase+rel, f'isa = PBXBuildFile; fileRef = {ref};')
        refs.append(ref); builds.append(build)
    return refs,builds

app_refs,app_builds=files(app_sources,'sources')
test_refs,test_builds=files(ui_sources,'tests')
unit_refs,unit_builds=files(unit_sources,'unit-tests')
unit_resource_refs,unit_resource_builds=files(unit_resources,'unit-test-resources')
resource_refs,resource_builds=files(resources,'resources')
for name in sorted({p.name for p in (ROOT/'Resources').glob('*.lproj/*.strings')}):
    children=[]
    for path in sorted((ROOT/'Resources').glob('*.lproj/'+name)):
        language=path.parent.stem
        children.append(obj('localized:'+str(path.relative_to(ROOT)),
            f'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {q(language)}; path = {q(path.relative_to(ROOT))}; sourceTree = SOURCE_ROOT;'))
    variant=obj('variant:'+name,f'isa = PBXVariantGroup; children = {arr(children)}; name = {q(name)}; sourceTree = "<group>";')
    resource_refs.append(variant)
    resource_builds.append(obj('variant-build:'+name,f'isa = PBXBuildFile; fileRef = {variant};'))
app_product=obj('app-product','isa = PBXFileReference; explicitFileType = wrapper.application; path = Capydoku.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product=obj('test-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CapydokuUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
unit_product=obj('unit-product','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CapydokuAppTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = {arr([app_product,test_product,unit_product])}; name = Products; sourceTree = "<group>";')
main_group=obj('main-group',f'isa = PBXGroup; children = {arr(app_refs+test_refs+unit_refs+resource_refs+unit_resource_refs+[configurations_group,products])}; sourceTree = "<group>";')
package=obj('core-package','isa = XCLocalSwiftPackageReference; relativePath = .;')
product_dep=obj('core-product',f'isa = XCSwiftPackageProductDependency; package = {package}; productName = CapydokuCore;')
core_build=obj('core-build',f'isa = PBXBuildFile; productRef = {product_dep};')
def phase(name, isa, builds):
    return obj(name, f'isa = {isa}; buildActionMask = 2147483647; files = {arr(builds)}; runOnlyForDeploymentPostprocessing = 0;')
app_src=phase('app-src','PBXSourcesBuildPhase',app_builds)
app_res=phase('app-res','PBXResourcesBuildPhase',resource_builds)
app_frameworks=phase('app-frameworks','PBXFrameworksBuildPhase',[core_build])
test_src=phase('test-src','PBXSourcesBuildPhase',test_builds)
test_res=phase('test-res','PBXResourcesBuildPhase',[])
test_frameworks=phase('test-frameworks','PBXFrameworksBuildPhase',[])
unit_src=phase('unit-src','PBXSourcesBuildPhase',unit_builds)
unit_res=phase('unit-res','PBXResourcesBuildPhase',unit_resource_builds)
unit_frameworks=phase('unit-frameworks','PBXFrameworksBuildPhase',[])

def configs(prefix,settings):
    ids=[]
    for name, configuration_file in configuration_files.items():
        merged=dict(settings)
        merged['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if name=='Debug' else '-O'
        merged['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG' if name=='Debug' else ''
        merged['DEBUG_INFORMATION_FORMAT']='dwarf' if name=='Debug' else 'dwarf-with-dsym'
        # Project-level inheritance also gives test bundles the matching
        # environment identity without duplicating settings at each target.
        base = f'baseConfigurationReference = {configuration_refs[configuration_file]}; ' if prefix == 'project-' else ''
        ids.append(obj(prefix+name,'isa = XCBuildConfiguration; name = '+name+'; '+base+'buildSettings = {'+' '.join((q(k) if '[' in k else k)+' = '+q(v)+';' for k,v in merged.items())+'};'))
    return obj(prefix+'list',f'isa = XCConfigurationList; buildConfigurations = {arr(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_config=configs('project-',{'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'15.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','ENABLE_TESTABILITY':'YES','ONLY_ACTIVE_ARCH':'YES'})
app_config=configs('app-',{'PRODUCT_NAME':'Capydoku','PRODUCT_BUNDLE_IDENTIFIER':'$(CAPYDOKU_APP_BUNDLE_IDENTIFIER)','INFOPLIST_FILE':'App/Info.plist','GENERATE_INFOPLIST_FILE':'NO','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_IDENTITY[sdk=iphonesimulator*]':'-','CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]':'App/Simulator.entitlements','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SUPPORTS_MACCATALYST':'NO','SWIFT_EMIT_LOC_STRINGS':'YES'})
test_config=configs('uitest-',{'PRODUCT_NAME':'CapydokuUITests','PRODUCT_BUNDLE_IDENTIFIER':'$(CAPYDOKU_APP_BUNDLE_IDENTIFIER).uitests','GENERATE_INFOPLIST_FILE':'YES','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','TEST_TARGET_NAME':'Capydoku','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
unit_config=configs('unit-',{'PRODUCT_NAME':'CapydokuAppTests','PRODUCT_BUNDLE_IDENTIFIER':'$(CAPYDOKU_APP_BUNDLE_IDENTIFIER).apptests','GENERATE_INFOPLIST_FILE':'YES','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','BUNDLE_LOADER':'$(TEST_HOST)','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Capydoku.app/Capydoku','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
app_target=obj('app-target',f'isa = PBXNativeTarget; buildConfigurationList = {app_config}; buildPhases = {arr([app_src,app_frameworks,app_res])}; buildRules = (); dependencies = (); name = Capydoku; packageProductDependencies = {arr([product_dep])}; productName = Capydoku; productReference = {app_product}; productType = "com.apple.product-type.application";')
proxy=obj('test-proxy',f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = Capydoku;')
dependency=obj('test-dependency',f'isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};')
test_target=obj('test-target',f'isa = PBXNativeTarget; buildConfigurationList = {test_config}; buildPhases = {arr([test_src,test_frameworks,test_res])}; buildRules = (); dependencies = {arr([dependency])}; name = CapydokuUITests; productName = CapydokuUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing";')
unit_target=obj('unit-target',f'isa = PBXNativeTarget; buildConfigurationList = {unit_config}; buildPhases = {arr([unit_src,unit_frameworks,unit_res])}; buildRules = (); dependencies = {arr([dependency])}; name = CapydokuAppTests; productName = CapydokuAppTests; productReference = {unit_product}; productType = "com.apple.product-type.bundle.unit-test";')
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; TargetAttributes = {{ {app_target} = {{ CreatedOnToolsVersion = 26.0; }}; {test_target} = {{ CreatedOnToolsVersion = 26.0; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base); mainGroup = {main_group}; packageReferences = {arr([package])}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {arr([app_target,test_target,unit_target])};')
out=ROOT/'Capydoku.xcodeproj';out.mkdir(exist_ok=True)
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{k} = {{ {v} }};' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
scheme=out/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
ref=lambda target,name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Capydoku.xcodeproj"/>'
def write_scheme(name, run_configuration, archive_configuration, include_tests=True):
    # Functional tests use the original Debug scheme and its dedicated fixtures.
    # Candidate packages are verified by explicit build/normal-launch audits.
    testables = (f'<TestableReference skipped="NO">{ref(test_target,"CapydokuUITests.xctest")}</TestableReference>'
                 f'<TestableReference skipped="NO">{ref(unit_target,"CapydokuAppTests.xctest")}</TestableReference>') if include_tests else ''
    (scheme/f'{name}.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app_target,'Capydoku.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="{run_configuration}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testables}</Testables></TestAction>
<LaunchAction buildConfiguration="{run_configuration}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_target,'Capydoku.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="{archive_configuration}" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_target,'Capydoku.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="{run_configuration}"/><ArchiveAction buildConfiguration="{archive_configuration}" revealArchiveInOrganizer="YES"/>
</Scheme>''')
write_scheme('Capydoku', 'Debug', 'Release')
for configuration in ('TestFlight', 'Staging', 'Production'):
    write_scheme(f'Capydoku-{configuration}', configuration, configuration, include_tests=False)
print(f'Generated {out} ({len(app_sources)} app sources, {len(ui_sources)} UI test sources)')
