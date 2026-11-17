#!/usr/bin/env python3
"""Reject an XSA whose PCIe address map cannot support the AMR HPU firmware."""
import argparse
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile


def validate_xsa(xsa, interface):
    number = lambda key: int(interface[key], 0)
    pcie_base = 0x20100000000
    with zipfile.ZipFile(xsa) as archive:
        root = ET.fromstring(archive.read('hpu_plug.hwh'))
        noc = ET.fromstring(archive.read('hpu_plug_axi_noc_cips_0.hwh'))
    ranges = [r.attrib for r in root.iter('MEMRANGE')
              if r.get('MASTERBUSINTERFACE') == 'CPM_PCIE_NOC_0']

    def require(instance, base, size):
        matches = [r for r in ranges if r['INSTANCE'] == instance
                   and int(r['BASEVALUE'], 0) == base
                   and int(r['HIGHVALUE'], 0) + 1 == base + size]
        if len(matches) != 1:
            raise ValueError(f'AMR address mismatch: {instance} expected {base:#x}+{size:#x}')

    require('noc_wrapper_ddr_noc_axi_noc_mc_ddr4_0', pcie_base,
            number('management_bytes'))
    instances = ['REGIF_AXI_0_1', 'REGIF_AXI_0_0', 'REGIF_AXI_1_1',
                 'REGIF_AXI_1_0', 'MHDMA_AXI_0', 'MHDMA_AXI_1']
    reg = number('hpu_register_bar_offset')
    if reg < number('management_bytes') or reg + number('hpu_register_bytes') > number('bar0_bytes'):
        raise ValueError('HPU registers overlap management or exceed BAR0')
    for i, name in enumerate(instances):
        require(name, pcie_base + reg + i * 0x10000, 0x10000)
    triples = []
    for node in noc.iter('PARAMETER'):
        if node.get('NAME') == 'REMAPS':
            triples.extend(tuple(int(x.replace('_', ''), 16) for x in match)
                           for match in re.findall(r'\{(0x[\da-fA-F_]+)\s+(0x[\da-fA-F_]+)\s+(0x[\da-fA-F_]+)\}', node.get('VALUE', '')))
    expected = [(pcie_base, number('management_ddr_base'), number('management_bytes'))]
    expected += [(pcie_base + reg + i * 0x10000, 0x20180000000 + i * 0x10000, 0x10000)
                 for i in range(6)]
    for mapping in expected:
        if triples.count(mapping) != 1:
            raise ValueError(f'AMR NoC remap mismatch: {mapping}')
    return {'schema_version': 1, 'management_mapping': 'verified', 'hpu_register_mapping': 'verified'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xsa', type=Path)
    parser.add_argument('--interface', type=Path,
                        default=Path(__file__).resolve().parent.parent / 'amr/interface.json')
    args = parser.parse_args()
    print(json.dumps(validate_xsa(args.xsa, json.loads(args.interface.read_text())), indent=2))
