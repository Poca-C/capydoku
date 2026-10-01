"""Audit actual .app/.xcarchive contents for local listening-resource isolation."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib

parser=argparse.ArgumentParser()
parser.add_argument('artifact',type=Path)
parser.add_argument('--expect',choices=['present','absent'],required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
app=args.artifact
if app.suffix=='.xcarchive':
    apps=list((app/'Products/Applications').glob('*.app'))
    if len(apps)!=1:raise SystemExit('Archive must contain exactly one app')
    app=apps[0]
if not app.is_dir() or app.suffix!='.app':raise SystemExit('Expected built .app or .xcarchive')
info=plistlib.loads((app/'Info.plist').read_bytes())
files=[p for p in app.rglob('*') if p.is_file()]
local=[p for p in files if 'LocalReferenceAudio' in p.parts or p.name.startswith('meow-test-') or p.name=='local-test-audio.json']
formal=json.loads((app/'audio-manifest.json').read_text())
errors=[]
if formal.get('referenceVerified') is not False or formal.get('clips')!={}:errors.append('Formal audio manifest was modified')
if args.expect=='absent' and local:errors.append('Reference listening files found in excluded build')
if args.expect=='present':
    manifest=app/'LocalReferenceAudio/local-test-audio.json'
    if not manifest.is_file():errors.append('Local listening manifest missing')
    else:
        doc=json.loads(manifest.read_text());expected=set(doc['files'])|{'local-test-audio.json'}
        if set(p.name for p in local)!=expected:errors.append('Local resource inventory differs from manifest')
        if info.get('CapydokuEnvironment')!='internal_demo':errors.append('Unexpected build environment')
        if doc.get('referenceVerified') is not False or doc['playback'].get('referenceVerified') is not False:errors.append('Local manifest claimed formal reference verification')
        for name,sha in doc['files'].items():
            path=manifest.parent/name
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=sha:errors.append('Hash mismatch: '+name)
report={'artifact':str(args.artifact),'bundleVersion':info.get('CFBundleShortVersionString'),'build':info.get('CFBundleVersion'),'environment':info.get('CapydokuEnvironment'),'expectation':args.expect,'passed':not errors,'errors':errors,'formalAudioReferenceVerified':formal.get('referenceVerified'),'totalRegularFiles':len(files),'localTestFiles':[{'path':str(p.relative_to(app)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(local)],'resourceInventory':[str(p.relative_to(app)) for p in sorted(files)]}
args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['bundleVersion','build','environment','expectation','passed','errors']},ensure_ascii=False))
raise SystemExit(0 if not errors else 1)
