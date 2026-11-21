#!/usr/bin/env python3
"""Prepare derived grades only in an isolated Desktop benchmark folder.
Requires ffmpeg/ffprobe on PATH. Never modifies the copied OCF/Grades inputs.
Run the opt-in RenderBenchmarkTests with SOURCEPRINT_BENCHMARK_ROOT set afterwards.
"""
import argparse, json, subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('root', type=Path)
args = parser.parse_args()
root = args.root.resolve()
manifest = json.loads((root / 'manifest.json').read_text())
source = next(Path(r['copy']) for r in manifest if '/Grades/' in r['copy'] and 'A004C0100_' in r['copy'])
ocf = next(Path(r['copy']) for r in manifest if '/OCF/' in r['copy'] and 'A004C0100_' in r['copy'])
probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(ocf)]))
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
assert video['r_frame_rate'] == '25/1' and video['width'] == 4096
count = int(video['nb_frames'])
tc = video['tags']['timecode']
h, m, s, f = map(int, tc.split(':'))
base = ((h * 60 + m) * 60 + s) * 25 + f
fixtures = root / 'Derived'
fixtures.mkdir(exist_ok=True)

def grade(start, frames, suffix=''):
    path = fixtures / f'grade-{start}-{frames}{suffix}.mov'
    frame = base + start
    timecode = f'{frame // 90000:02}:{frame // 1500 % 60:02}:{frame // 25 % 60:02}:{frame % 25:02}'
    if not path.exists():
        subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-stream_loop', '-1', '-i', str(source),
                        '-map', '0:v:0', '-c', 'copy', '-frames:v', str(frames), '-an',
                        '-timecode', timecode, str(path)], check=True)
    return str(path)

cases = []
for coverage in (10, 49, 51, 90, 99, 100):
    frames = max(1, round(count * coverage / 100))
    start = (count - frames) // 2
    cases.append(dict(name=f'coverage-{coverage}', ocf=str(ocf), grades=[grade(start, frames)]))
cases.append(dict(name='full-multiple', ocf=str(ocf), grades=[grade(0, 100), grade(100, count - 100)]))
cases.append(dict(name='one-frame-gap', ocf=str(ocf), grades=[grade(0, 100), grade(101, count - 101)]))
cases.append(dict(name='fragmented-51', ocf=str(ocf), grades=[grade(i, min(10, count - i)) for i in range(0, count, 20)]))
for prefix in ('A004C0098_', 'A004C0100_', 'DSCF0781'):
    a = next(r['copy'] for r in manifest if '/OCF/' in r['copy'] and Path(r['copy']).name.startswith(prefix))
    b = next(r['copy'] for r in manifest if '/Grades/' in r['copy'] and Path(r['copy']).name.startswith(prefix))
    cases.append(dict(name=f'real-{prefix.rstrip("_")}', ocf=a, grades=[b]))
# A shared-cache revision sequence: shorten, lengthen, shift, then repeat unchanged.
revisions = [dict(name=n, ocf=str(ocf), grades=[grade(start, frames)]) for n, start, frames in
             [('initial', 20, 190), ('shorter', 40, 150), ('longer', 10, 210), ('shifted', 20, 210), ('unchanged', 20, 210)]]
(root / 'cases.json').write_text(json.dumps(dict(cases=cases, revisions=revisions), indent=2))
print(f'Prepared {len(cases)} scenarios and {len(revisions)} revisions in {root}')
