#!/usr/bin/env python3
"""Strict, offline Pawdoku gameplay-config importer. Never accepts maps or answers.

Input is a manually verified structured extraction, NOT competitor level files.
All values must come from the same archived baseline. Null template rows remain pending.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NULL = type(None)
SCHEMAS = {
    'root': {'schemaVersion': int, 'status': str, 'configVersion': (str, NULL),
             'baseline': ('baseline', NULL), 'importedSourceSHA256': (str, NULL), 'levels': list},
    'baseline': {'product': str, 'storeVersion': str, 'capturedAt': str, 'device': str,
                 'osVersion': str, 'sourceArchiveSHA256': str, 'evidenceFiles': list},
    'level': {'level': int, 'configuration': ('configuration', NULL)},
    'configuration': {'startingLives': int, 'directFind': 'tool', 'hint': 'tool',
                      'levelStartFreeAd': 'levelStartFreeAd', 'revive': 'revive',
                      'failure': 'failure', 'interstitial': 'interstitial', 'adsEnabled': bool,
                      'rewardedAdTimeoutSeconds': int, 'bannerEnabled': bool,
                      'bannerReviewEvidenceID': (str, NULL)},
    'tool': {'enabled': bool, 'visible': bool, 'unlockLevel': int, 'initialFreeCount': int,
             'firstUnlockBonusCount': int, 'inventoryAcrossLevels': str, 'regrantPolicy': str,
             'rewardedAdEnabled': bool, 'buttonState': str, 'evidenceID': str},
    'levelStartFreeAd': {'enabled': bool, 'visible': bool, 'freeCount': int, 'reward': str,
                         'rewardCount': int, 'resetPolicy': str, 'inventoryAcrossLevels': str,
                         'triggerOrder': int, 'buttonState': str, 'evidenceID': str},
    'revive': {'enabled': bool, 'rewardedAdEnabled': bool, 'restoredLives': int,
               'unlimitedRevives': bool, 'freeCount': int, 'resetPolicy': str, 'evidenceID': str},
    'failure': {'flowID': str, 'title': str, 'reviveButtonTitle': str, 'restartButtonTitle': str,
                'canDismiss': bool, 'restartCreatesNewBoard': bool, 'evidenceID': str},
    'interstitial': {'enabled': bool, 'startLevel': int, 'frequency': int, 'cooldownSeconds': int,
                     'adTimeoutSeconds': int, 'onNextLevel': bool, 'onReturnHome': bool, 'evidenceID': str}
}


def template():
    return {'schemaVersion': 1, 'status': 'awaiting_baseline', 'configVersion': None,
            'baseline': None, 'importedSourceSHA256': None,
            'levels': [{'level': level, 'configuration': None} for level in range(1, 151)]}


def blank_fields(kind):
    """Field worksheet only; null means unknown, never an assumed runtime value."""
    result = {}
    for key, expected in SCHEMAS[kind].items():
        nested = expected if isinstance(expected, str) else None
        result[key] = blank_fields(nested) if nested else None
    return result


def shape(value, kind='root', path='$'):
    errors = []
    if type(value) is not dict:
        return [f'{path}: expected an object']
    fields = SCHEMAS[kind]
    for key in sorted(set(value) - set(fields)):
        errors.append(f'{path}.{key}: prohibited or unknown field; competitor maps/answers may not be imported')
    for key in sorted(set(fields) - set(value)):
        errors.append(f'{path}.{key}: required field is missing')
    for key in value.keys() & fields.keys():
        expected, item, label = fields[key], value[key], f'{path}.{key}'
        choices = expected if isinstance(expected, tuple) else (expected,)
        if item is None and NULL in choices:
            continue
        nested = next((c for c in choices if isinstance(c, str)), None)
        if nested:
            errors += shape(item, nested, label)
        elif not any(type(item) is c for c in choices):
            errors.append(f'{label}: incorrect field type')
        elif key == 'levels':
            for index, entry in enumerate(item):
                errors += shape(entry, 'level', f'{label}[{index}]')
    return errors


def sha256(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def validate(data, imported=True):
    errors = shape(data)
    if errors:
        return errors
    def require(condition, message):
        if not condition:
            errors.append(message)
    require(data['schemaVersion'] == 1, 'Unsupported schemaVersion')
    require(data['status'] in ('awaiting_baseline', 'frozen'), 'Unknown baseline status')
    ids = [row['level'] for row in data['levels']]
    require(len(ids) == 150 and set(ids) == set(range(1, 151)), 'Exactly one entry per level 1–150 is required')
    if data['status'] == 'awaiting_baseline':
        require(data['configVersion'] is None and data['baseline'] is None and data['importedSourceSHA256'] is None,
                'Pending template must not claim a frozen version or checksum')
        require(all(row['configuration'] is None for row in data['levels']),
                'Pending template must not contain guessed configuration values')
        return errors
    require(bool(data['configVersion'] and data['configVersion'].strip()), 'Frozen configVersion is required')
    if imported:
        require(sha256(data['importedSourceSHA256']), 'Run importer to record imported source SHA256')
    baseline = data['baseline']
    require(baseline is not None, 'Capture metadata is required')
    if baseline:
        require(baseline['product'] == 'Pawdoku', 'Pawdoku is the sole reference product')
        require(all(baseline[k].strip() for k in ('storeVersion', 'device', 'osVersion')), 'Capture identity fields cannot be blank')
        try:
            captured = dt.datetime.fromisoformat(baseline['capturedAt'].replace('Z', '+00:00'))
            require(captured.utcoffset() == dt.timedelta(0), 'capturedAt must be a UTC ISO8601 timestamp')
        except (ValueError, TypeError):
            errors.append('capturedAt must be a UTC ISO8601 timestamp')
        require(sha256(baseline['sourceArchiveSHA256']), 'Archived source checksum must be a lowercase SHA256')
        require(bool(baseline['evidenceFiles']) and all(type(v) is str and v.strip() for v in baseline['evidenceFiles']),
                'At least one nonempty evidence file is required')
    for row in data['levels']:
        level, value = row['level'], row['configuration']
        prefix = f'Level {level}'
        require(value is not None, f'{prefix}: missing frozen configuration')
        if value is None:
            continue
        def bounds(number, low, high, field):
            require(low <= number <= high, f'{prefix}: {field} outside supported safety range {low}…{high}')
        bounds(value['startingLives'], 1, 99, 'startingLives')
        bounds(value['rewardedAdTimeoutSeconds'], 1, 120, 'rewardedAdTimeoutSeconds')
        require(not value['bannerEnabled'] or bool(value['bannerReviewEvidenceID'] and value['bannerReviewEvidenceID'].strip()),
                f'{prefix}: banner requires separate review evidence under original 8.1')
        for name in ('directFind', 'hint'):
            tool = value[name]
            bounds(tool['unlockLevel'], 1, 1_000_000, name + '.unlockLevel')
            for field in ('initialFreeCount', 'firstUnlockBonusCount'):
                bounds(tool[field], 0, 10_000, name + '.' + field)
            require(tool['inventoryAcrossLevels'] in ('retain', 'reset'), f'{prefix}: invalid {name} inventory policy')
            require(tool['regrantPolicy'] in ('once_per_level', 'every_attempt', 'never'), f'{prefix}: invalid {name} regrant policy')
            require(tool['buttonState'] in ('hidden', 'locked', 'enabled', 'disabled'), f'{prefix}: invalid {name} button state')
            require(tool['visible'] == (tool['buttonState'] != 'hidden'), f'{prefix}: inconsistent {name} visibility')
            require(not (tool['buttonState'] == 'enabled' and (not tool['enabled'] or level < tool['unlockLevel'])), f'{prefix}: unavailable {name} button cannot be enabled')
            require(not (level < tool['unlockLevel'] and tool['initialFreeCount'] > 0), f'{prefix}: {name} inventory granted before unlock')
            require(bool(tool['evidenceID'].strip()), f'{prefix}: {name} evidence required')
        hint = value['hint']
        require(hint['enabled'] and hint['visible'] and hint['unlockLevel'] == 1, f'{prefix}: hint must be available from level 1')
        free = value['levelStartFreeAd']
        for field in ('freeCount', 'rewardCount'):
            bounds(free[field], 0, 10_000, 'levelStartFreeAd.' + field)
        bounds(free['triggerOrder'], 0, 100, 'levelStartFreeAd.triggerOrder')
        require(free['reward'] in ('direct_find', 'hint'), f'{prefix}: invalid free-ad reward')
        require(free['resetPolicy'] in ('once_per_level', 'every_attempt', 'never'), f'{prefix}: invalid free-ad reset')
        require(free['inventoryAcrossLevels'] in ('retain', 'reset'), f'{prefix}: invalid free-ad carry')
        require(free['buttonState'] in ('hidden', 'locked', 'enabled', 'disabled'), f'{prefix}: invalid free-ad button state')
        require(free['visible'] == (free['buttonState'] != 'hidden'), f'{prefix}: inconsistent free-ad visibility')
        require(not (free['buttonState'] == 'enabled' and not free['enabled']), f'{prefix}: disabled free ad cannot be enabled')
        require(not (free['enabled'] and (free['freeCount'] == 0 or free['rewardCount'] == 0)), f'{prefix}: enabled free ad requires counts')
        require(bool(free['evidenceID'].strip()), f'{prefix}: free-ad evidence required')
        revive = value['revive']
        bounds(revive['restoredLives'], 1, 99, 'revive.restoredLives')
        bounds(revive['freeCount'], 0, 10_000, 'revive.freeCount')
        require(revive['restoredLives'] == value['startingLives'] and revive['unlimitedRevives'], f'{prefix}: original 8.4 requires full lives and unlimited revives')
        require(revive['resetPolicy'] in ('once_per_level', 'every_attempt', 'never'), f'{prefix}: invalid revive reset')
        require(bool(revive['evidenceID'].strip()), f'{prefix}: revive evidence required')
        failure = value['failure']
        require(all(failure[k].strip() for k in ('flowID', 'title', 'reviveButtonTitle', 'restartButtonTitle', 'evidenceID')), f'{prefix}: failure flow text and evidence required')
        interstitial = value['interstitial']
        for field, low, high in [('startLevel', 1, 1_000_000), ('frequency', 1, 10_000), ('cooldownSeconds', 0, 86_400), ('adTimeoutSeconds', 1, 120)]:
            bounds(interstitial[field], low, high, 'interstitial.' + field)
        require(bool(interstitial['evidenceID'].strip()), f'{prefix}: interstitial evidence required')
    return errors


def differences(old, new, path='$'):
    if type(old) is dict and type(new) is dict:
        return [change for key in sorted(set(old) | set(new))
                for change in differences(old.get(key), new.get(key), path + '.' + key)]
    if type(old) is list and type(new) is list:
        # Config rows compare by level, independent of source array ordering.
        if path == '$.levels':
            return differences({str(r['level']): r for r in old}, {str(r['level']): r for r in new}, path)
        return [] if old == new else [{'field': path, 'before': old, 'after': new}]
    return [] if old == new else [{'field': path, 'before': old, 'after': new}]


def encode(data):
    return (json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()


def write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Never leave a half-written frozen baseline after process interruption.
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encode(data))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def import_file(source, output, report, previous=None):
    raw = Path(source).read_bytes()
    data = json.loads(raw)
    errors = validate(data, imported=False)
    ready = not errors and data['status'] == 'frozen'
    result = copy.deepcopy(data)
    if ready:
        result['importedSourceSHA256'] = hashlib.sha256(raw).hexdigest()
        result['levels'].sort(key=lambda row: row['level'])
        errors += validate(result)
        ready = not errors
    comparison = None
    if previous:
        old = json.loads(Path(previous).read_bytes())
        prior_errors = validate(old)
        if prior_errors:
            errors += ['Previous baseline invalid: ' + error for error in prior_errors]
            ready = False
        else:
            comparison = differences(old, result)
            if old['status'] == 'frozen' and ready:
                substantive = [v for v in comparison if v['field'] != '$.importedSourceSHA256']
                if substantive and old['configVersion'] == result['configVersion']:
                    errors.append('Changed frozen values require a new configVersion and review; refusing silent baseline replacement')
                    ready = False
    validation = {'schemaVersion': 1, 'sourceFile': str(Path(source).resolve()),
                  'sourceFileSHA256': hashlib.sha256(raw).hexdigest(),
                  'configVersion': data.get('configVersion'), 'status': data.get('status'),
                  'readyForUse': ready, 'levelCount': len(data.get('levels', [])),
                  'errors': errors, 'fieldDifferences': comparison,
                  'outputSHA256': hashlib.sha256(encode(result)).hexdigest() if ready else None,
                  'note': 'Importer does not verify authenticity of supplied captures. Human review of cited evidence is required; no competitor board data is accepted.'}
    write(report, validation)
    if ready:
        write(output, result)
    return validation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', nargs='?')
    parser.add_argument('--output', default='Resources/reference-gameplay.json')
    parser.add_argument('--report', default='Validation/reference-gameplay-import.json')
    parser.add_argument('--previous', help='Previous imported baseline for field-level diff and version checks')
    parser.add_argument('--write-template', help='Write a pending 150-level template; no guessed values')
    parser.add_argument('--write-row-worksheet', help='Write required fields with null placeholders (not importable)')
    args = parser.parse_args()
    if args.write_template:
        write(args.write_template, template())
        return 0
    if args.write_row_worksheet:
        write(args.write_row_worksheet, blank_fields('configuration'))
        return 0
    if not args.source:
        parser.error('Supply a structured source capture or --write-template')
    try:
        report = import_file(args.source, args.output, args.report, args.previous)
    except (OSError, ValueError, TypeError) as error:
        write(args.report, {'readyForUse': False, 'errors': [str(error)]})
        print(f'REJECTED: {error}', file=sys.stderr)
        return 1
    print('IMPORTED: 150 verified configuration rows' if report['readyForUse'] else 'NOT READY: ' + '; '.join(report['errors'] or ['Frozen source baseline has not been supplied']))
    return 0 if report['readyForUse'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
