import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from stage_local_test_audio import DIRECTORY, PURPOSE, stage

class LocalAudioBuildIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'input'; self.source.mkdir()
        self.destination = self.root / 'Capydoku.app' / DIRECTORY
        self.name = 'meow-test-fixture.wav'
        self.data = b'local test resource fixture, not reference audio'
        (self.source / self.name).write_bytes(self.data)
        self.document = {'schemaVersion': 1, 'purpose': PURPOSE, 'allowedEnvironment': 'internal_demo',
                         'referenceVerified': False, 'files': {self.name: hashlib.sha256(self.data).hexdigest()},
                         'playback': {'referenceVerified': False, 'clips': {'mark_x': {'file': self.name}}}}
        self.write_manifest()
        self.env = {'CONFIGURATION': 'Debug', 'CAPYDOKU_ENVIRONMENT': 'internal_demo', 'ACTION': 'build'}
    def tearDown(self): self.temp.cleanup()
    def write_manifest(self):
        (self.source / 'local-test-audio.json').write_text(json.dumps(self.document))
    def test_debug_internal_copy(self):
        self.assertEqual(stage(self.source, self.destination, self.env), 1)
        self.assertEqual((self.destination/self.name).read_bytes(), self.data)
    def test_all_distribution_configs_clear_prior_debug_copy(self):
        for configuration in ['Release','TestFlight','Staging','Production']:
            with self.subTest(configuration=configuration):
                stage(self.source,self.destination,self.env)
                self.assertEqual(stage(self.source,self.destination,self.env|{'CONFIGURATION':configuration}),0)
                self.assertFalse(self.destination.exists())
    def test_all_candidate_environments_reject_debug(self):
        for environment in ['testing','staging','production','unconfigured','']:
            with self.subTest(environment=environment):
                self.assertEqual(stage(self.source,self.destination,self.env|{'CAPYDOKU_ENVIRONMENT':environment}),0)
    def test_archive_or_deployment_rejects_even_debug(self):
        for override in [{'ACTION':'install'},{'ACTION':'archive'},{'DEPLOYMENT_LOCATION':'YES'}]:
            with self.subTest(override=override):
                stage(self.source,self.destination,self.env)
                self.assertEqual(stage(self.source,self.destination,self.env|override),0)
                self.assertFalse(self.destination.exists())
    def test_missing_inputs_clear_previous_build(self):
        stage(self.source,self.destination,self.env)
        (self.source/'local-test-audio.json').unlink()
        self.assertEqual(stage(self.source,self.destination,self.env),0)
        self.assertFalse(self.destination.exists())
    def test_hash_mismatch_fails_closed(self):
        stage(self.source,self.destination,self.env)
        (self.source/self.name).write_bytes(b'tampered')
        with self.assertRaises(ValueError):stage(self.source,self.destination,self.env)
        self.assertFalse(self.destination.exists())
    def test_path_traversal_rejected(self):
        self.document['files']={'../outside.wav':'0'*64}
        self.document['playback']['clips']['mark_x']['file']='../outside.wav';self.write_manifest()
        with self.assertRaises(ValueError):stage(self.source,self.destination,self.env)
    def test_reference_verified_claim_rejected(self):
        self.document['playback']['referenceVerified']=True;self.write_manifest()
        with self.assertRaises(ValueError):stage(self.source,self.destination,self.env)

if __name__=='__main__': unittest.main()
