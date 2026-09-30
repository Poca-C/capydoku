"""Importer tests use an explicitly fabricated row, never production reference values."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import import_reference_gameplay as importer


class GameplayImportTests(unittest.TestCase):
    def fixture(self):
        row = json.loads((importer.ROOT / 'Tests/Fixtures/reference-gameplay-synthetic-row.json').read_text())
        return {'schemaVersion': 1, 'status': 'frozen', 'configVersion': 'synthetic-tests-only-v1',
                'baseline': {'product': 'Pawdoku', 'storeVersion': 'test-only', 'capturedAt': '2026-09-30T00:00:00Z',
                             'device': 'test-only', 'osVersion': 'test-only', 'sourceArchiveSHA256': 'a' * 64,
                             'evidenceFiles': ['synthetic-test-only']},
                'importedSourceSHA256': None,
                'levels': [{'level': level, 'configuration': copy.deepcopy(row)} for level in range(1, 151)]}

    def test_pending_template_is_not_imported_and_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            source, output, report = [Path(folder) / p for p in ('source.json', 'output.json', 'report.json')]
            importer.write(source, importer.template())
            output.write_bytes(b'previous baseline')
            result = importer.import_file(source, output, report)
            self.assertFalse(result['readyForUse'])
            self.assertEqual(output.read_bytes(), b'previous baseline')
            self.assertEqual(result['levelCount'], 150)

    def test_complete_import_records_source_checksum_and_diff(self):
        with tempfile.TemporaryDirectory() as folder:
            source, previous, output, report = [Path(folder) / p for p in ('source.json', 'previous.json', 'output.json', 'report.json')]
            data = self.fixture()
            importer.write(source, data)
            first = importer.import_file(source, previous, report)
            self.assertTrue(first['readyForUse'], first['errors'])
            prior = json.loads(previous.read_bytes())
            self.assertEqual(prior['importedSourceSHA256'], hashlib.sha256(source.read_bytes()).hexdigest())
            data['configVersion'] = 'synthetic-tests-only-v2'
            data['levels'][6]['configuration']['directFind']['initialFreeCount'] = 8
            importer.write(source, data)
            result = importer.import_file(source, output, report, previous)
            self.assertTrue(result['readyForUse'], result['errors'])
            change = next(c for c in result['fieldDifferences'] if c['field'] == '$.levels.7.configuration.directFind.initialFreeCount')
            self.assertEqual((change['before'], change['after']), (2, 8))
            self.assertEqual(result['outputSHA256'], hashlib.sha256(output.read_bytes()).hexdigest())

    def test_same_version_changed_baseline_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            source, output, previous, report = [Path(folder) / p for p in ('source.json', 'output.json', 'previous.json', 'report.json')]
            data = self.fixture()
            importer.write(source, data)
            importer.import_file(source, previous, report)
            data['levels'][0]['configuration']['hint']['initialFreeCount'] = 9
            importer.write(source, data)
            result = importer.import_file(source, output, report, previous)
            self.assertFalse(result['readyForUse'])
            self.assertFalse(output.exists())
            self.assertTrue(any('new configVersion' in e for e in result['errors']))

    def test_nested_map_alias_is_rejected_without_dropping_it(self):
        data = self.fixture()
        data['levels'][0]['configuration']['hint']['region_map'] = [1, 2]
        self.assertTrue(any('region_map' in e for e in importer.validate(data, imported=False)))

    def test_boolean_inventory_and_duplicate_level_are_rejected(self):
        data = self.fixture()
        data['levels'][0]['configuration']['hint']['initialFreeCount'] = True
        self.assertTrue(any('incorrect field type' in e for e in importer.validate(data, imported=False)))
        data = self.fixture()
        data['levels'][-1]['level'] = 1
        self.assertTrue(any('Exactly one' in e for e in importer.validate(data, imported=False)))

    def test_missing_fields_and_non_utc_capture_are_rejected(self):
        data = self.fixture()
        del data['levels'][0]['configuration']['failure']['flowID']
        self.assertTrue(any('required field' in e for e in importer.validate(data, imported=False)))
        data = self.fixture()
        data['baseline']['capturedAt'] = '2026-09-30T12:00:00+08:00'
        self.assertTrue(any('UTC' in e for e in importer.validate(data, imported=False)))


if __name__ == '__main__':
    unittest.main()
