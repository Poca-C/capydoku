#!/usr/bin/env python3
"""Real UI -> cold restore -> uninstall/reinstall audit on a NEW disposable simulator.

No app data is injected or edited. The only app-container access is read-only
observation and evidence copying. Requires OperationReinstallUITests in the
Xcode project; the script builds once in a unique, private DerivedData directory.
Simulator ad-hoc signing is not physical-device or App Store verification.
"""
import argparse
import base64
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=root / "Capydoku.xcodeproj")
    parser.add_argument("--scheme", default="Capydoku")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17e")
    parser.add_argument("--output-dir", type=Path, required=True, help="New, empty evidence directory; existing runs are never overwritten")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report_path = output / "audit.json"
    token = uuid.uuid4().hex[:12]
    derived = root / ".build" / ("OperationReinstallAudit-" + token)
    report = {
        "startedAt": datetime.now(timezone.utc).isoformat(), "status": "running",
        "scope": "Real UI actions and real local-container uninstall/reinstall on a newly created iOS simulator",
        "excluded": ["Physical-device provisioning/signing", "App Store install/review", "iCloud or device-backup restoration", "Real advertising SDK/network", "Formal anonymous-identity reinstall policy"],
        "noSaveInjection": True, "allowedLaunchArguments": ["-ui-testing", "-test-first-launch"],
        "derivedData": str(derived), "steps": [], "cleanup": {},
        "coldRestoreAllowedChanges": {
            "session.elapsedSeconds": "Nondecreasing elapsed play time while the second UI stage observes the game",
            "session.resultPhase": "Exactly +1 for the one real Continue -> Home play phase in the cold-restore UI stage",
            "analyticsQueue": "Existing event prefix unchanged; real cold-launch/session/quit events may append; reward events must not duplicate"
        }
    }
    device = None
    bundle = None

    def save_report():
        temporary = report_path.with_suffix(".pending.json")
        temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        temporary.replace(report_path)

    def command(arguments, *, check=True, timeout=60, log=None):
        arguments = list(map(str, arguments))
        entry = {"arguments": arguments, "startedAt": datetime.now(timezone.utc).isoformat()}
        report["steps"].append(entry)
        stream = (output / log).open("w") if log else None
        started = time.monotonic()
        process = subprocess.Popen(arguments, cwd=root, stdout=stream or subprocess.PIPE,
                                   stderr=subprocess.STDOUT if stream else subprocess.PIPE,
                                   text=True, start_new_session=True)
        entry["pid"] = process.pid
        if log: entry["log"] = str(output / log)
        report["activeProcess"] = {"pid": process.pid, "command": arguments[0], "log": entry.get("log")}
        save_report()
        print(json.dumps({"event": "process_started", **report["activeProcess"]}), flush=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try: process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); process.communicate()
            entry["timedOut"] = True
            raise
        finally:
            if stream: stream.close()
            entry["seconds"] = round(time.monotonic() - started, 3)
            entry["exitCode"] = process.returncode
            report.pop("activeProcess", None)
            save_report()
        entry["stdout"] = (stdout or "").strip()[-3000:]
        entry["stderr"] = (stderr or "").strip()[-3000:]
        save_report()
        print(json.dumps({"event": "process_finished", "pid": process.pid, "exitCode": process.returncode, "log": entry.get("log")}), flush=True)
        if check and process.returncode:
            raise RuntimeError(f"{arguments[0]} failed ({process.returncode}); see {entry.get('log') or entry['stderr']}")
        return subprocess.CompletedProcess(arguments, process.returncode, stdout or "", stderr or "")

    def sim(*parts, **kwargs): return command(["xcrun", "simctl", *parts], **kwargs)
    def sha(data): return hashlib.sha256(data).hexdigest()

    def app_fingerprint(app):
        files = {str(path.relative_to(app)): sha(path.read_bytes()) for path in sorted(app.rglob("*")) if path.is_file()}
        return sha(json.dumps(files, sort_keys=True).encode())

    def observe(stage, bundle):
        container = Path(sim("get_app_container", device, bundle, "data").stdout.strip())
        folder = container / "Library/Application Support/CapydokuUITesting"
        path = folder / "progress.json"
        deadline = time.monotonic() + 20
        while not path.is_file() and time.monotonic() < deadline: time.sleep(0.2)
        raw = path.read_bytes()
        envelope = json.loads(raw)
        payload = base64.b64decode(envelope["payload"], validate=True)
        assert sha(payload) == envelope["checksum"], "Progress checksum mismatch"
        progress = json.loads(payload)
        # Evidence copies go to the audit directory, never back into the app.
        (output / f"{stage}-progress-envelope.json").write_bytes(raw)
        (output / f"{stage}-progress.json").write_text(json.dumps(progress, indent=2, ensure_ascii=False) + "\n")
        queue = json.loads((folder / "analytics-demo-queue.json").read_text())
        (output / f"{stage}-analytics.json").write_text(json.dumps(queue, indent=2, ensure_ascii=False) + "\n")
        consent = folder / "consent.json"
        if consent.exists(): (output / f"{stage}-consent.json").write_bytes(consent.read_bytes())
        report[stage] = {"dataContainer": str(container), "saveSHA256": sha(raw), "saveBytes": len(raw),
                         "checksumValid": True, "eventCount": len(queue["events"]), "rewardCount": len(progress["rewardLedger"])}
        save_report()
        return progress, queue, path

    def normalized(progress):
        value = copy.deepcopy(progress)
        for key in ["completedLevels", "freeToolGrantedLevels", "referenceToolGrantKeys"]:
            if key in value: value[key] = sorted(value[key])
        session = value.get("session")
        if session:
            for key in ["found", "marks", "errors"]: session[key] = sorted(session[key])
            session.pop("elapsedSeconds", None)
            session.pop("resultPhase", None)
        return value

    def rewarded_events(queue):
        return [event for event in queue["events"] if event["event_name"] in ("ad_offer_shown", "ad_result")]

    def run_ui(stage, method, xctestrun):
        result = output / f"{stage}.xcresult"
        command(["xcodebuild", "test-without-building", "-xctestrun", xctestrun,
                 "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                 "-resultBundlePath", result, "-only-testing:CapydokuUITests/OperationReinstallUITests/" + method],
                timeout=420, log=f"{stage}.log")
        summary = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result]).stdout)
        (output / f"{stage}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        assert summary.get("totalTestCount") == 1 and summary.get("passedTests") == 1 and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0, "Dedicated UI stage was not actually executed and passed"
        tree = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", result]).stdout)
        (output / f"{stage}-tests.json").write_text(json.dumps(tree, indent=2) + "\n")
        cases = []
        def collect(node):
            if isinstance(node, dict):
                if node.get("nodeType") == "Test Case": cases.append(node)
                for value in node.values(): collect(value)
            elif isinstance(node, list):
                for value in node: collect(value)
        collect(tree)
        assert len(cases) == 1 and cases[0]["result"] == "Passed", "Unexpected test cases in the result bundle"
        assert cases[0]["name"].removesuffix("()") == method, "xctestrun did not execute the requested stage"
        report.setdefault("uiStages", []).append({"stage": stage, "expectedMethod": method, "observedMethod": cases[0]["name"],
            "passedTests": 1, "failedTests": 0, "skippedTests": 0, "resultBundle": str(result)})
        save_report()
        command(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                 "--output-path", output / f"{stage}-attachments"], timeout=60)

    try:
        save_report()
        project_text = (args.project / "project.pbxproj").read_text()
        assert "OperationReinstallUITests.swift" in project_text, "Regenerate the Xcode project before running this audit"
        name = "Capydoku-Operation-Reinstall-Audit-" + token
        device = sim("create", name, args.device_type, args.runtime).stdout.strip()
        uuid.UUID(device)
        report["temporaryDevice"] = {"name": name, "udid": device, "runtime": args.runtime, "deviceType": args.device_type}
        save_report()
        sim("boot", device)
        for attempt in range(6):
            try:
                sim("bootstatus", device, "-b", timeout=30)
                break
            except subprocess.TimeoutExpired:
                if attempt == 5: raise
                print(json.dumps({"event": "boot_still_provisioning", "device": device, "attempt": attempt + 1}), flush=True)
        command(["xcodebuild", "build-for-testing", "-project", args.project.resolve(), "-scheme", args.scheme,
                 "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", derived,
                 "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-"],
                timeout=900, log="build-for-testing.log")
        products = derived / "Build/Products"
        originals = sorted(products.glob("*.xctestrun"))
        assert len(originals) == 1, f"Expected one fresh xctestrun file, got {len(originals)}"
        configuration = plistlib.loads(originals[0].read_bytes())
        enabled = 0

        def enable(node):
            nonlocal enabled
            if isinstance(node, dict):
                if node.get("BlueprintName") == "CapydokuUITests" or "CapydokuUITests.xctest" in node.get("TestBundlePath", ""):
                    node.setdefault("EnvironmentVariables", {})["CAPYDOKU_OPERATION_REINSTALL_AUDIT"] = "1"
                    enabled += 1
                for value in list(node.values()): enable(value)
            elif isinstance(node, list):
                for value in node: enable(value)
        enable(configuration)
        assert enabled > 0, "Could not opt in the dedicated UI test host"
        xctestrun = products / "operation-reinstall.xctestrun"
        xctestrun.write_bytes(plistlib.dumps(configuration))
        app = products / "Debug-iphonesimulator/Capydoku.app"
        info = plistlib.loads((app / "Info.plist").read_bytes())
        bundle = info["CFBundleIdentifier"]
        frozen_sha = app_fingerprint(app)
        pack_bytes = (app / "levels.json").read_bytes()
        board = next(row for row in json.loads(pack_bytes) if row["id"] == 1)
        assert board["size"] == 4 and 8 in board["solution"]
        assert board["regions"].count(board["regions"][8]) == 1
        assert set([0, 4, 5, 9, 13]).isdisjoint(board["solution"]), "Installed tutorial path changed; update the real UI regression deliberately"
        report["build"] = {"appVersion": info.get("CFBundleShortVersionString"), "appBuild": info.get("CFBundleVersion"),
                           "bundleID": bundle, "appPath": str(app), "appTreeSHA256": frozen_sha,
                           "levelPackSHA256": sha(pack_bytes), "signing": "simulator ad hoc only", "xctestrun": str(xctestrun)}
        save_report()
        run_ui("01-real-ui-state", "test01CreatePersistentStateThroughUI", xctestrun)
        before, before_queue, original_save = observe("beforeColdRestore", bundle)
        assert before["tutorialCompleted"] and before["tutorialStep"] == 9
        assert before["currentLevel"] == 1 and before["session"]["attempt"] == 1
        assert len(before["session"]["found"]) == 3 and before["session"]["marks"] and before["session"]["errors"]
        assert before["session"]["lives"] == 2 and before["session"]["score"] > 0
        assert before["checkIn"]["streak"] == 1 and before["checkIn"]["cycleDay"] == 1
        assert before["bonusHints"] == 1 and before["session"]["hintsRemaining"] == 1
        assert before["session"]["directRemaining"] == 0 and before["bonusDirect"] == 0
        assert before["settings"]["language"] == "en"
        assert all(not before["settings"][key] for key in ["musicEnabled", "soundEnabled", "voiceEnabled", "hapticsEnabled"])
        assert len(before["rewardLedger"]) == 1 and next(iter(before["rewardLedger"].values()))["state"] == "executed"
        ads = rewarded_events(before_queue)
        assert [event["event_name"] for event in ads] == ["ad_offer_shown", "ad_result", "ad_result"]
        assert [event["parameters"].get("status") for event in ads[1:]] == ["started", "completed"]
        assert all(event["parameters"]["network"] == "simulation" for event in ads)
        assert ads[-1]["parameters"]["reward_granted"] is True
        run_ui("02-cold-ui-restore", "test02VerifyColdRestoreThroughUI", xctestrun)
        cold, cold_queue, current_save = observe("afterColdRestore", bundle)
        assert normalized(cold) == normalized(before), "Cold restore changed player state outside the explicit elapsed/result-phase allowlist"
        assert cold["session"]["elapsedSeconds"] >= before["session"]["elapsedSeconds"]
        assert cold["session"]["resultPhase"] == before["session"]["resultPhase"] + 1
        assert cold["session"].get("resultPhaseEnd") == before["session"].get("resultPhaseEnd") == "quit"
        report["coldRestoreObservedChanges"] = {
            "session.elapsedSeconds": {"before": before["session"]["elapsedSeconds"], "after": cold["session"]["elapsedSeconds"]},
            "session.resultPhase": {"before": before["session"]["resultPhase"], "after": cold["session"]["resultPhase"]},
            "allOtherPlayerPayloadFieldsExactlyEqual": True,
            "unorderedSetFieldsNormalizedOnly": ["completedLevels", "freeToolGrantedLevels", "referenceToolGrantKeys", "session.found", "session.marks", "session.errors"]
        }
        assert cold_queue["events"][:len(before_queue["events"])] == before_queue["events"], "Cold restore rewrote historical event attribution"
        assert rewarded_events(cold_queue) == ads, "Cold restore repeated or changed a simulated reward event"
        report["coldRestoreExactPlayerStateComparisonPassed"] = True
        assert app_fingerprint(app) == frozen_sha, "Built app changed between stages"
        sim("uninstall", device, bundle)
        absent = sim("get_app_container", device, bundle, "data", check=False)
        assert absent.returncode != 0 and not current_save.exists(), "Uninstall retained a registered app container or old save"
        report["uninstall"] = {"containerLookupFails": True, "oldSaveAbsent": True}
        save_report()
        sim("install", device, app)
        fresh_container = Path(sim("get_app_container", device, bundle, "data").stdout.strip())
        assert not (fresh_container / "Library/Application Support/CapydokuUITesting").exists(), "Reinstall unexpectedly restored app data"
        run_ui("03-reinstalled-ui-defaults", "test03VerifyInitialStateAfterReinstallThroughUI", xctestrun)
        reset, reset_queue, _ = observe("afterReinstall", bundle)
        assert reset["currentLevel"] == 1 and reset["unlockedLevel"] == 1
        assert reset.get("session") is None and reset["completedLevels"] == [] and reset["attemptCounts"] == {}
        assert not reset["tutorialCompleted"] and reset["tutorialStep"] == 0
        assert reset["bonusHints"] == 0 and reset["bonusDirect"] == 0 and reset["rewardLedger"] == {}
        assert reset["checkIn"].get("lastClaimedDay") is None
        assert all(reset["checkIn"][key] == 0 for key in ["streak", "cycleDay", "completedCycles"])
        assert reset["settings"]["language"] == "zh-Hans"
        assert all(reset["settings"][key] for key in ["musicEnabled", "soundEnabled", "voiceEnabled", "hapticsEnabled"])
        assert reset["freeToolGrantedLevels"] == [] and reset["referenceToolGrantKeys"] == []
        for key in ["levelToolBalances", "levelStartLocalBalances", "freeReviveUsage", "pendingBuffEvents", "pendingLevelResultEvents"]:
            assert reset[key] == {}, f"Reinstall retained {key}"
        assert reset.get("activeHintUse") is None and reset.get("experimentalHistoryCheckpoint") is None
        assert reset["carriedToolBalance"] == {"hints": 0, "direct": 0}
        assert rewarded_events(reset_queue) == []
        assert app_fingerprint(app) == frozen_sha, "Reinstall did not use the same frozen build"
        report["allInitialLocalStateChecksPassed"] = True
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
        if device and bundle:
            try: observe("failureObservedState", bundle)
            except BaseException as snapshot_error: report["failureSnapshotError"] = f"{type(snapshot_error).__name__}: {snapshot_error}"
    finally:
        if device:
            try:
                sim("shutdown", device, check=False)
                deleted = sim("delete", device, check=False)
                report["cleanup"] = {"deleted": deleted.returncode == 0, "onlyCreatedDeviceTargeted": device}
                if deleted.returncode != 0: report["status"] = "failed"
            except BaseException as error:
                report["cleanup"] = {"deleted": False, "error": f"{type(error).__name__}: {error}"}
                report["status"] = "failed"
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save_report()
        print(json.dumps({"status": report["status"], "report": str(report_path), "temporaryDeviceDeleted": report["cleanup"].get("deleted"), "error": report.get("error")}, ensure_ascii=False), flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
