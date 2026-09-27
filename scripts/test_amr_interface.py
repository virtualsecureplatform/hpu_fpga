"""AMR image contract tests; no hardware or licensed tools required."""
import json
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'fw/arm/scripts'))
from check_amr_interface import validate_xsa
from verify_amr_release import verify


class AmrInterfaceTests(unittest.TestCase):
    def setUp(self):
        self.interface = json.loads((ROOT / 'fw/arm/amr/interface.json').read_text())
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.xsa = Path(self.temp.name) / 'fixture.xsa'

    def fixture(self, register_base=0x02000000, ddr_base=0x10000000):
        root, noc = ET.Element('EDKSYSTEM'), ET.Element('EDKSYSTEM')
        instances = ['noc_wrapper_ddr_noc_axi_noc_mc_ddr4_0', 'REGIF_AXI_0_1',
                     'REGIF_AXI_0_0', 'REGIF_AXI_1_1', 'REGIF_AXI_1_0', 'MHDMA_AXI_0', 'MHDMA_AXI_1']
        for i, instance in enumerate(instances):
            offset, length = (0, 0x800000) if i == 0 else (register_base + (i-1)*0x10000, 0x10000)
            ET.SubElement(root, 'MEMRANGE', INSTANCE=instance, MASTERBUSINTERFACE='CPM_PCIE_NOC_0',
                          BASEVALUE=hex(0x20100000000 + offset), HIGHVALUE=hex(0x20100000000 + offset + length - 1))
        triples = [(0x20100000000, ddr_base, 0x800000)]
        triples += [(0x20100000000 + register_base + i*0x10000, 0x20180000000 + i*0x10000, 0x10000) for i in range(6)]
        ET.SubElement(noc, 'PARAMETER', NAME='REMAPS', VALUE=' '.join(
            '{' + ' '.join(hex(n) for n in triple) + '}' for triple in triples))
        with zipfile.ZipFile(self.xsa, 'w') as archive:
            archive.writestr('hpu_plug.hwh', ET.tostring(root))
            archive.writestr('hpu_plug_axi_noc_cips_0.hwh', ET.tostring(noc))

    def test_matching_address_map(self):
        self.fixture()
        self.assertEqual(validate_xsa(self.xsa, self.interface)['management_mapping'], 'verified')

    def release_fixture(self):
        self.fixture()
        root = self.xsa.parent
        self.xsa.rename(root / 'hpu_plug.xsa')
        (root / 'amc.elf').write_bytes(b'test-only firmware')
        pdi = root / 'hpu_psi64_350mhz_amr.pdi'
        pdi.write_bytes(b'test-only image')
        (root / 'interface.json').write_text(json.dumps(self.interface))
        digest = lambda name: hashlib.sha256((root / name).read_bytes()).hexdigest()
        (root / 'firmware.json').write_text(json.dumps({
            'management_stack': 'AMR-3.0', 'interface': self.interface,
            'elf_sha256': digest('amc.elf'), 'xsa_sha256': digest('hpu_plug.xsa')}))
        manifest = {'schema_version': 1, 'management_stack': 'AMR-3.0',
                    'expected_uuid': '00000000000000000000000012345678',
                    'sha256': {name: digest(name) for name in
                               (pdi.name, 'amc.elf', 'hpu_plug.xsa', 'interface.json', 'firmware.json')}}
        (root / 'release_manifest.json').write_text(json.dumps(manifest))
        return pdi

    def test_release_integrity(self):
        pdi = self.release_fixture()
        self.assertEqual(verify(pdi)['management_stack'], 'AMR-3.0')
        pdi.write_bytes(b'changed image')
        with self.assertRaisesRegex(ValueError, 'artifact changed'):
            verify(pdi)

    def test_release_requires_uuid(self):
        pdi = self.release_fixture()
        path = pdi.parent / 'release_manifest.json'
        manifest = json.loads(path.read_text())
        del manifest['expected_uuid']
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'logic UUID'):
            verify(pdi)

    def test_old_register_map_rejected(self):
        self.fixture(register_base=0x100000)
        with self.assertRaises(ValueError):
            validate_xsa(self.xsa, self.interface)

    def test_wrong_ddr_remap_rejected(self):
        self.fixture(ddr_base=0x38000000)
        with self.assertRaisesRegex(ValueError, 'NoC remap'):
            validate_xsa(self.xsa, self.interface)

    def test_reserved_status_and_queues_do_not_overlap(self):
        n = lambda k: int(self.interface[k], 0)
        ranges = [(n('management_ddr_base'), n('management_ddr_base') + n('management_bytes')),
                  (n('ack_head'), n('ack_tail') + 4),
                  (0x39000000, 0x3d000000), (0x3d000000, 0x3f000000),
                  (n('iop_head'), n('iop_tail') + 4), (0x40000000, 0x7e800000)]
        for a, b in zip(sorted(ranges), sorted(ranges)[1:]):
            self.assertLessEqual(a[1], b[0])
        self.assertEqual(n('status_bar_offset') + 0x1000, n('management_bytes'))

    def test_actual_previous_release_is_rejected(self):
        old = ROOT / 'versal/timing_350_image_restored_20260915/release/hpu_plug.xsa'
        if not old.exists():
            self.skipTest('Previous release is not present')
        with self.assertRaisesRegex(ValueError, 'AMR address mismatch'):
            validate_xsa(old, self.interface)


if __name__ == '__main__':
    unittest.main()
