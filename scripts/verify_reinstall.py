#!/usr/bin/env python3
"""Verify local uninstall/reinstall behavior on a disposable simulator only.

Example:
  python3 scripts/verify_reinstall.py --app DerivedData/Build/Products/Debug-iphonesimulator/Capydoku.app

No pre-existing simulator or real device is modified. This does not test iCloud,
device backups, App Store installation, or real-device behavior.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17e")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "Validation/reinstall-audit.json")
    args = parser.parse_args()
    app = args.app.resolve()
    report = {
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "status": "running", "scope": "Disposable iOS simulator, local app container only",
        "exclusions": ["Physical device", "iCloud or device backup restore", "App Store installation"],
        "sourceApp": str(app), "runtime": args.runtime, "deviceType": args.device_type,
        "steps": [], "cleanup": {},
    }
    if args.output.exists():
        previous = json.loads(args.output.read_text())
        if previous.get("status") == "failed":
            history = previous.get("previousFailedAttempts", [])
            if previous.get("previousFailedAttempt"):
                history.append(previous["previousFailedAttempt"])
            history.append({key: previous.get(key) for key in
                            ("startedAt", "status", "error", "temporaryDevice", "cleanup")})
            report["previousFailedAttempts"] = history[-5:]
    device = None

    def command(*parts, check=True, timeout=60, record_output=True):
        arguments = ["xcrun", "simctl", *map(str, parts)]
        started = time.monotonic()
        try:
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            report["steps"].append({"arguments": arguments, "timedOut": True, "seconds": timeout,
                                    "stdout": (error.stdout or b"").decode(errors="replace")[-2000:]})
            raise
        report["steps"].append({"arguments": arguments, "exitCode": result.returncode,
                                "seconds": round(time.monotonic() - started, 3),
                                "stdout": result.stdout.strip()[-2000:] if record_output else "(inventory omitted)",
                                "stderr": result.stderr.strip()[-2000:]})
        if check and result.returncode:
            raise RuntimeError(f"simctl {parts[0]} failed: {result.stderr.strip()}")
        return result

    def read_progress(path):
        envelope = json.loads(path.read_text())
        payload_bytes = base64.b64decode(envelope["payload"], validate=True)
        assert hashlib.sha256(payload_bytes).hexdigest() == envelope["checksum"], "Checksum mismatch"
        return json.loads(payload_bytes)

    def wait_for_file(path):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if path.is_file():
                return read_progress(path)
            time.sleep(0.2)
        raise RuntimeError(f"Expected save was not created: {path}")

    def summary(progress):
        session = progress.get("session")
        return {"currentLevel": progress["currentLevel"], "unlockedLevel": progress["unlockedLevel"],
                "tutorialCompleted": progress["tutorialCompleted"], "bonusHints": progress["bonusHints"],
                "bonusDirect": progress["bonusDirect"], "completedLevels": progress["completedLevels"],
                "checkIn": progress["checkIn"],
                "rewardCount": len(progress["rewardLedger"]), "hasSession": session is not None,
                "sessionID": session.get("id") if session else None,
                "sessionLevel": session["puzzle"]["id"] if session else None,
                "boardSize": session["puzzle"]["size"] if session else None}

    try:
        with (app / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        bundle = info["CFBundleIdentifier"]
        report["bundleID"] = bundle
        report["appVersion"] = info.get("CFBundleShortVersionString")
        report["appBuild"] = info.get("CFBundleVersion")
        # Freeze one build so simultaneous development builds cannot alter the second install.
        with tempfile.TemporaryDirectory(prefix="capydoku-reinstall-app-") as temp:
            frozen_app = Path(temp) / app.name
            shutil.copytree(app, frozen_app, symlinks=True)
            executable = frozen_app / info["CFBundleExecutable"]
            report["executableSHA256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
            name = f"Capydoku-Reinstall-Audit-{uuid.uuid4().hex[:8]}"
            device = command("create", name, args.device_type, args.runtime).stdout.strip()
            uuid.UUID(device)  # Refuse to continue unless simctl returned an actual device ID.
            report["temporaryDevice"] = {"name": name, "udid": device}
            command("boot", device)
            # Fresh-device provisioning can be slow with other simulator tests running.
            # Each wait is bounded; killing the status client does not stop the device boot.
            for attempt in range(6):
                try:
                    command("bootstatus", device, "-b", timeout=30)
                    break
                except subprocess.TimeoutExpired:
                    if attempt == 5:
                        raise
                    print(f"Temporary simulator is provisioning; boot check {attempt + 1}/6", flush=True)
            command("install", device, frozen_app)
            original_container = Path(command("get_app_container", device, bundle, "data").stdout.strip())
            original_save = original_container / "Library/Application Support/CapydokuUITesting/progress.json"
            command("launch", device, bundle, "-ui-testing", "-skip-tutorial", "-level", "150")
            wait_for_file(original_save)
            command("terminate", device, bundle)
            before = read_progress(original_save)
            assert before["currentLevel"] == 150 and before["session"]["puzzle"]["id"] == 150
            assert before["session"]["puzzle"]["size"] == 10
            report["originalLevelSave"] = {"progress": summary(before), "checksumValid": True}
            # Fixture injection is restricted to this disposable app container. It proves
            # cleanup of non-empty data; it is not evidence that the Check-in button works.
            fixture_check_in = {"lastClaimedDay": int(time.time() // 86400) - 1,
                                "streak": 3, "cycleDay": 3, "completedCycles": 2}
            before["bonusHints"] = 7
            before["bonusDirect"] = 4
            before["checkIn"] = fixture_check_in
            envelope = json.loads(original_save.read_text())
            fixture_payload = json.dumps(before, sort_keys=True, separators=(",", ":")).encode()
            envelope["payload"] = base64.b64encode(fixture_payload).decode()
            envelope["checksum"] = hashlib.sha256(fixture_payload).hexdigest()
            # Unknown envelope keys are valid on read, but the app's own encoder drops them.
            # Its disappearance is direct evidence that the app re-saved the loaded fixture.
            envelope["fixtureAuditMarker"] = "disposable-reinstall-test"
            original_save.write_text(json.dumps(envelope, sort_keys=True, separators=(",", ":")))
            report["fixture"] = {"method": "Injected checksum-valid test state while app was terminated",
                                 "scope": "Only the newly created simulator's app container",
                                 "bonusHints": 7, "bonusDirect": 4, "checkIn": fixture_check_in,
                                 "notClaimedByThisTest": "Actual check-in button behavior"}
            command("launch", device, bundle, "-ui-testing")
            time.sleep(2)
            command("launch", device, "com.apple.Preferences")
            # Backgrounding must rewrite the fixture via the app, proving it loaded the data.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and "fixtureAuditMarker" in json.loads(original_save.read_text()):
                time.sleep(0.2)
            assert "fixtureAuditMarker" not in json.loads(original_save.read_text()), "App did not rewrite the loaded fixture"
            command("terminate", device, bundle)
            before = read_progress(original_save)
            assert before["currentLevel"] == 150 and before["session"]["puzzle"]["id"] == 150
            assert before["bonusHints"] == 7 and before["bonusDirect"] == 4
            assert before["checkIn"] == fixture_check_in
            report["fixture"]["appReloadAndBackgroundPersistenceConfirmed"] = True
            report["beforeUninstall"] = {"dataContainer": str(original_container), "progress": summary(before),
                                         "saveBytes": original_save.stat().st_size, "checksumValid": True}
            command("uninstall", device, bundle)
            lookup = command("get_app_container", device, bundle, "data", check=False)
            assert lookup.returncode != 0, "Uninstalled app still has a registered data container"
            assert not original_save.exists(), "Old save survived uninstall"
            report["uninstall"] = {"oldSaveAbsent": True, "containerLookupFails": True}
            command("install", device, frozen_app)
            new_container = Path(command("get_app_container", device, bundle, "data").stdout.strip())
            new_save = new_container / "Library/Application Support/CapydokuUITesting/progress.json"
            assert not new_save.exists(), "Reinstall unexpectedly restored the old save"
            command("launch", device, bundle, "-ui-testing")
            # Let the home screen initialize, then background normally to persist its initial state.
            time.sleep(2)
            report["afterReinstallBeforeBackground"] = {"dataContainer": str(new_container),
                                                        "saveFileAbsentBeforeBackground": not new_save.exists()}
            command("launch", device, "com.apple.Preferences")
            after = wait_for_file(new_save)
            command("terminate", device, bundle)
            after = read_progress(new_save)
            assert after["currentLevel"] == 1 and after["unlockedLevel"] == 1
            assert after.get("session") is None and after["completedLevels"] == []
            assert after["bonusHints"] == 0 and after["bonusDirect"] == 0
            assert not after["tutorialCompleted"] and after["tutorialStep"] == 0
            assert after["checkIn"].get("lastClaimedDay") is None
            assert after["checkIn"]["streak"] == 0 and after["checkIn"]["cycleDay"] == 0
            assert after["checkIn"]["completedCycles"] == 0
            assert after["rewardLedger"] == {}, "Reward ledger survived reinstall"
            report["afterReinstall"] = {"progress": summary(after), "saveBytes": new_save.stat().st_size,
                                        "checksumValid": True, "initialProgressConfirmed": True}
            report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        # The only target eligible for deletion is the device just created above.
        if device:
            try:
                command("shutdown", device, check=False)
                deleted = command("delete", device, check=False)
                inventory = json.loads(command("list", "devices", "--json", record_output=False).stdout)
                exists = any(item["udid"] == device for group in inventory["devices"].values() for item in group)
                report["cleanup"] = {"deleted": deleted.returncode == 0 and not exists,
                                     "deviceAbsentFromInventory": not exists}
                if not report["cleanup"]["deleted"]:
                    report["status"] = "failed"
                    report["cleanup"]["error"] = "Disposable simulator was not deleted"
            except BaseException as error:
                report["status"] = "failed"
                report["cleanup"] = {"deleted": False, "error": f"{type(error).__name__}: {error}"}
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps({"status": report["status"], "report": str(args.output),
                          "temporaryDeviceDeleted": report["cleanup"].get("deleted"),
                          "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
