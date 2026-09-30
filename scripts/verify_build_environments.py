"""Check resolved Xcode environment settings without compiling or installing."""
from pathlib import Path
import hashlib
import json
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = (
    ("Debug", "Capydoku", "internal_demo", "com.capydoku.demo", "Capydoku"),
    ("Release", "Capydoku", "internal_demo", "com.capydoku.demo", "Capydoku"),
    ("TestFlight", "Capydoku-TestFlight", "testing", "com.capydoku.demo.testing", "Capydoku 测试"),
    ("Staging", "Capydoku-Staging", "staging", "com.capydoku.demo.staging", "Capydoku 预发布"),
    ("Production", "Capydoku-Production", "production", "com.capydoku.demo.production", "Capydoku 正式候选"),
)
INFO_SETTINGS = {
    "CFBundleDisplayName": "CAPYDOKU_APP_DISPLAY_NAME",
    "CFBundleIdentifier": "PRODUCT_BUNDLE_IDENTIFIER",
    "CapydokuEnvironment": "CAPYDOKU_ENVIRONMENT",
    "CapydokuRemoteConfigurationEnabled": "CAPYDOKU_REMOTE_CONFIGURATION_ENABLED",
    "CapydokuRemoteConfigurationEnvironment": "CAPYDOKU_REMOTE_CONFIGURATION_ENVIRONMENT",
    "CapydokuRemoteConfigurationURL": "CAPYDOKU_REMOTE_CONFIGURATION_URL",
    "CapydokuAnalyticsEnabled": "CAPYDOKU_ANALYTICS_ENABLED",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check():
    info = plistlib.loads((ROOT / "App/Info.plist").read_bytes())
    for key, setting in INFO_SETTINGS.items():
        require(info.get(key) == f"$({setting})", f"Info.plist {key} must use {setting}")
    isolated_bundles = [row[3] for row in EXPECTED[2:]]
    require(len(set(isolated_bundles)) == 3 and "com.capydoku.demo" not in isolated_bundles,
            "TestFlight, Staging and Production must have separate app identities")
    rows = []
    for configuration, scheme, environment, bundle, display_name in EXPECTED:
        result = subprocess.run([
            "xcodebuild", "-project", "Capydoku.xcodeproj", "-scheme", scheme,
            "-configuration", configuration, "-sdk", "iphonesimulator",
            "-showBuildSettings", "-json",
        ], cwd=ROOT, capture_output=True, text=True, check=True)
        targets = json.loads(result.stdout)
        app_targets = [target for target in targets if target.get("target") == "Capydoku"]
        require(len(app_targets) == 1, f"{configuration}: expected one Capydoku target")
        settings = app_targets[0]["buildSettings"]
        expected_values = {
            "PRODUCT_BUNDLE_IDENTIFIER": bundle,
            "CAPYDOKU_APP_BUNDLE_IDENTIFIER": bundle,
            "CAPYDOKU_APP_DISPLAY_NAME": display_name,
            "CAPYDOKU_ENVIRONMENT": environment,
            "CAPYDOKU_REMOTE_CONFIGURATION_ENVIRONMENT": environment,
            "CAPYDOKU_REMOTE_CONFIGURATION_ENABLED": "NO",
            "CAPYDOKU_REMOTE_CONFIGURATION_URL": "",
            "CAPYDOKU_ANALYTICS_ENABLED": "YES",
            "MARKETING_VERSION": "0.2.21",
            "CURRENT_PROJECT_VERSION": "24",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O",
        }
        for key, expected in expected_values.items():
            # Xcode omits explicitly empty user build settings from this output.
            actual = settings.get(key, "")
            require(actual == expected, f"{configuration}: {key} was {actual!r}, expected {expected!r}")
        conditions = settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
        require(("DEBUG" in conditions) == (configuration == "Debug"),
                f"{configuration}: incorrect DEBUG compilation condition")
        rows.append({
            "configuration": configuration,
            "scheme": scheme,
            "settings": {key: settings.get(key, "") for key in expected_values},
            "swiftActiveCompilationConditions": conditions,
        })
    scheme_dir = ROOT / "Capydoku.xcodeproj/xcshareddata/xcschemes"
    for scheme, run_config, archive_config in (
        ("Capydoku", "Debug", "Release"),
        ("Capydoku-TestFlight", "TestFlight", "TestFlight"),
        ("Capydoku-Staging", "Staging", "Staging"),
        ("Capydoku-Production", "Production", "Production"),
    ):
        document = ET.parse(scheme_dir / f"{scheme}.xcscheme").getroot()
        for action in ("LaunchAction", "TestAction", "AnalyzeAction"):
            require(document.find(action).get("buildConfiguration") == run_config,
                    f"{scheme}: incorrect {action} configuration")
        for action in ("ProfileAction", "ArchiveAction"):
            require(document.find(action).get("buildConfiguration") == archive_config,
                    f"{scheme}: incorrect {action} configuration")
        testables = document.findall("./TestAction/Testables/TestableReference")
        require(len(testables) == (2 if scheme == "Capydoku" else 0),
                f"{scheme}: functional test suites belong only to the original Debug scheme")
    sources = [ROOT / "App/Info.plist", ROOT / "scripts/generate_project.py"]
    sources += sorted((ROOT / "Configurations").glob("*.xcconfig"))
    sources += sorted(scheme_dir.glob("Capydoku*.xcscheme"))
    return {
        "scope": "Resolved Xcode settings and shared schemes only; no build, signing, installation or external service connection.",
        "status": "passed",
        "placeholderPublisherIdentities": True,
        "analyticsTransport": "local-only",
        "remoteConfigurationEnabled": False,
        "rows": rows,
        "sourceSHA256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources
        },
    }


if __name__ == "__main__":
    try:
        print(json.dumps(check(), ensure_ascii=False, indent=2))
    except (ValueError, subprocess.CalledProcessError, ET.ParseError, OSError) as error:
        print(f"Build environment audit failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
