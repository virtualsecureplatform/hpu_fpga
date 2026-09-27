#!/usr/bin/env python3
"""Continue a managed fresh build through gated image generation."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('build', type=Path)
parser.add_argument('image', type=Path)
parser.add_argument('--source-build', type=Path)
args = parser.parse_args()
build, image = args.build.resolve(), args.image.resolve()
unit = (build / 'systemd_unit').read_text().strip()
while True:
    status = json.loads((build / 'status.json').read_text())
    if status['state'] == 'failed':
        sys.exit(f"Fresh build failed: {status.get('error', 'see status.json')}")
    active = subprocess.run(['systemctl', '--user', 'is-active', '--quiet', unit]).returncode == 0
    if status['state'] == 'complete' and not active:
        break
    time.sleep(10)
recovery = (build / 'recovery.complete').is_file()
if not recovery and not (build / 'fresh.complete').is_file():
    sys.exit('Fresh build has no completion marker')
signoff = build / ('signoff' if recovery else 'top_hpu/prj.runs/impl_1/signoff')
if not (signoff / 'signoff.json').is_file():
    sys.exit('Routing signoff did not pass; see signoff_failure.txt and signoff reports')
checkpoint = build / ('postroute_physopt.dcp' if recovery else 'top_hpu/prj.runs/impl_1/postroute_physopt.dcp')
source = args.source_build.resolve() if args.source_build else build
config = json.loads((build / 'build.json').read_text())
if not checkpoint.is_file():
    sys.exit(f'Missing post-route checkpoint: {checkpoint}')
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'versal/scripts'))
from check_timing_signoff import verify_signed
try:
    verify_signed(signoff, checkpoint)
except (ValueError, OSError, KeyError) as error:
    sys.exit(f'Signoff revalidation failed: {error}')
runner = Path(__file__).resolve().with_name('run_timing_build.py')
subprocess.run([sys.executable, runner, image, '--source-build', source,
                '--checkpoint', checkpoint, '--phase', 'image',
                '--memory-high-gib', str(config.get('memory_high_gib', 56)),
                '--memory-max-gib', str(config.get('memory_max_gib', 64)),
                '--start-memory-gib', str(config.get('start_memory_gib', 64))], check=True)
print(f'Image generation launched in {image}', flush=True)
