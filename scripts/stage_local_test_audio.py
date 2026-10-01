"""Stage local-only reference listening files; never part of any archive/distribution.

No audio is downloaded or extracted by builds. This optional input is ignored by Git.
Every build clears the previous output first, including incremental configuration swaps.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil

DIRECTORY = 'LocalReferenceAudio'
PURPOSE = 'local-user-authorized-audio-test'

def eligible(env):
    return (env.get('CONFIGURATION') == 'Debug'
            and env.get('CAPYDOKU_ENVIRONMENT') == 'internal_demo'
            and env.get('ACTION') not in {'install', 'archive', 'installhdrs', 'installapi'}
            and env.get('DEPLOYMENT_LOCATION', 'NO') != 'YES')

def stage(source: Path, destination: Path, env):
    # This function owns exactly one generated directory, never the app bundle.
    if destination.name != DIRECTORY:
        raise ValueError('Unexpected local-audio output directory')
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    if not eligible(env) or not (source / 'local-test-audio.json').is_file():
        return 0
    document = json.loads((source / 'local-test-audio.json').read_text())
    if (document.get('schemaVersion') != 1 or document.get('purpose') != PURPOSE
            or document.get('allowedEnvironment') != 'internal_demo'
            or document.get('referenceVerified') is not False
            or document.get('playback', {}).get('referenceVerified') is not False):
        raise ValueError('Invalid local audio test manifest')
    files = document.get('files', {})
    expected = {v['file'] for v in document['playback']['clips'].values()}
    if not files or set(files) != expected:
        raise ValueError('Local audio file inventory must match playback exactly')
    for name, checksum in files.items():
        if not re.fullmatch(r'meow-test-[a-z0-9_]+\.wav', name):
            raise ValueError('Unsafe local audio file name')
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Local audio input must be a regular file')
        if hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
            raise ValueError('Local audio checksum mismatch')
    # Validation completes before creating the destination: no partial usable import.
    destination.mkdir(parents=True)
    for name in sorted(files):
        shutil.copyfile(source / name, destination / name)
    shutil.copyfile(source / 'local-test-audio.json', destination / 'local-test-audio.json')
    return len(files)

if __name__ == '__main__':
    env = os.environ
    root = Path(env['SRCROOT'])
    app_resources = Path(env['TARGET_BUILD_DIR']) / env['UNLOCALIZED_RESOURCES_FOLDER_PATH']
    count = stage(root / 'LocalTestAssets/MeowdokuAudio', app_resources / DIRECTORY, env)
    print(f'Local reference listening resources: {count}; distribution/archive resources: disabled')
