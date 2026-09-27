#!/usr/bin/env python3
"""Offline release preflight. Does not program or access a board."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from check_amr_interface import validate_xsa


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(pdi):
    root = pdi.resolve().parent
    manifest = json.loads((root / 'release_manifest.json').read_text())
    if manifest.get('schema_version') != 1 or manifest.get('management_stack') != 'AMR-3.0':
        raise ValueError('Not a validated AMR HPU release')
    uuid = manifest.get('expected_uuid', '')
    if not isinstance(uuid, str) or not re.fullmatch(r'[0-9a-f]{32}', uuid) or int(uuid, 16) == 0:
        raise ValueError('Invalid AMR logic UUID')
    for name in ('hpu_psi64_350mhz_amr.pdi', 'hpu_plug.xsa', 'amc.elf', 'interface.json', 'firmware.json'):
        if sha256(root / name) != manifest['sha256'][name]:
            raise ValueError(f'Release artifact changed: {name}')
    if pdi.resolve() != root / 'hpu_psi64_350mhz_amr.pdi':
        raise ValueError('PDI does not match the release manifest')
    if not 0 < pdi.stat().st_size <= 0x07400000:
        raise ValueError('PDI exceeds the validated boot-partition capacity')
    interface = json.loads((root / 'interface.json').read_text())
    validate_xsa(root / 'hpu_plug.xsa', interface)
    firmware = json.loads((root / 'firmware.json').read_text())
    if firmware.get('management_stack') != 'AMR-3.0' or firmware.get('interface') != interface:
        raise ValueError('Firmware interface mismatch')
    if firmware['elf_sha256'] != sha256(root / 'amc.elf') or firmware['xsa_sha256'] != sha256(root / 'hpu_plug.xsa'):
        raise ValueError('Firmware was built against different artifacts')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdi', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.pdi), indent=2))
