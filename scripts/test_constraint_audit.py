"""Inactive vendor pins require exact identities and current netlist proof."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'versal/scripts'))
from constraint_audit import EXPECTED, EXPECTED_DRIVERS, audit, config_identity, constraints_digest


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.report = ('checking unconstrained_internal_endpoints (56)\n'
                       'There are 56 pins that are not constrained for maximum delay due to constant clock. (MEDIUM)\n\n'
                       + '\n'.join(sorted(EXPECTED)) + '\n\n5. checking no_input_delay (0)\n')
        (self.root / 'check_timing.rpt').write_text(self.report)
        (self.root / 'cips.xci').write_text(json.dumps({'ip_inst': {
            'component_reference': 'xilinx.com:ip:versal_cips:3.4', 'ip_revision': '10',
            'parameters': {'component_parameters': {'TEST': 1}}}}))
        (self.root / 'inactive_gt_policy.json').write_text(json.dumps({
            'tool_version': '2026.1', 'cips': config_identity(self.root / 'cips.xci')}))
        (self.root / 'gt_evidence_metadata.json').write_text('{"tool_version": "2026.1"}')
        self.evidence = '\n'.join(f'{pin}\tGTYP_QUAD\tGND\t1\tGND\t1' for pin in sorted(EXPECTED))
        (self.root / 'gt_endpoint_evidence.tsv').write_text(self.evidence)

    def test_exact_inactive_set_passes(self):
        result = audit(self.root)
        self.assertEqual((result['raw'], result['justified'], result['unresolved']), (56, 56, 0))

    def test_active_pin_is_not_exempted(self):
        (self.root / 'gt_endpoint_evidence.tsv').write_text(self.evidence.replace('\tGND\t1', '\tsignal\t0', 1))
        self.assertEqual(audit(self.root)['unresolved'], 1)

    def test_additional_or_replaced_endpoint_is_rejected(self):
        (self.root / 'check_timing.rpt').write_text(self.report.replace(sorted(EXPECTED)[0], 'other/D'))
        with self.assertRaisesRegex(ValueError, 'differ'):
            audit(self.root)

    def test_missing_evidence_is_rejected(self):
        (self.root / 'gt_endpoint_evidence.tsv').write_text('\n'.join(self.evidence.splitlines()[1:]))
        with self.assertRaisesRegex(ValueError, 'Missing or additional'):
            audit(self.root)

    def test_changed_ip_configuration_is_rejected(self):
        path = self.root / 'cips.xci'
        path.write_text(path.read_text().replace('"TEST": 1', '"TEST": 2'))
        with self.assertRaisesRegex(ValueError, 'configuration changed'):
            audit(self.root)

    def test_changed_tool_is_rejected(self):
        (self.root / 'gt_evidence_metadata.json').write_text('{"tool_version": "2026.2"}')
        with self.assertRaisesRegex(ValueError, 'configuration changed'):
            audit(self.root)

    def vendor_fixture(self):
        policy_path = self.root / 'inactive_gt_policy.json'
        policy = json.loads(policy_path.read_text())
        constraints = 'current_instance CPM\nset_case_analysis 0 [get_pins clock]\n'
        policy['vendor_cpm'] = {'constraints_sha256': constraints_digest(constraints)}
        policy_path.write_text(json.dumps(policy))
        (self.root / 'gt_checkpoint_constraints.xdc').write_text(constraints)
        (self.root / 'gt_cpm_drivers.tsv').write_text('\n'.join(
            f'{pin}\t{driver}\tCPM5\t0' for pin, driver in EXPECTED_DRIVERS.items()))
        (self.root / 'gt_endpoint_evidence.tsv').write_text(
            self.evidence.replace('\tGND\t1', '\tsignal\t0'))

    def test_exact_vendor_set_is_justified_not_inactive(self):
        self.vendor_fixture()
        result = audit(self.root)
        self.assertEqual(result['justified'], 56)
        self.assertEqual(result['unresolved'], 0)
        self.assertTrue(all(not e['inactive'] for e in result['endpoints']))

    def test_vendor_rejects_changed_driver_primitive_or_clock(self):
        for old, new in [('IFFCQ20', 'IFFCQ30'), ('CPM5', 'LUT1'), ('\t0', '\t1')]:
            with self.subTest(new=new):
                self.vendor_fixture()
                path = self.root / 'gt_cpm_drivers.tsv'
                path.write_text(path.read_text().replace(old, new, 1))
                with self.assertRaisesRegex(ValueError, 'evidence changed'):
                    audit(self.root)

    def test_vendor_rejects_missing_or_duplicate_driver_rows(self):
        for duplicate in (False, True):
            self.vendor_fixture()
            path = self.root / 'gt_cpm_drivers.tsv'
            lines = path.read_text().splitlines()
            path.write_text('\n'.join(lines + lines[:1] if duplicate else lines[1:]))
            with self.assertRaises(ValueError):
                audit(self.root)

    def test_vendor_rejects_constraint_override(self):
        self.vendor_fixture()
        path = self.root / 'gt_checkpoint_constraints.xdc'
        path.write_text(path.read_text() + 'reset_case_analysis [get_pins clock]\n')
        with self.assertRaisesRegex(ValueError, 'constraints changed'):
            audit(self.root)

    def test_constraint_digest_ignores_comments_and_generated_waiver_time(self):
        self.assertEqual(constraints_digest('# filename a\ncmd arg\n'),
                         constraints_digest('# filename b\n\ncmd arg\n'))
        self.assertNotEqual(constraints_digest('cmd arg\ncmd other'),
                            constraints_digest('cmd other\ncmd arg'))
        waiver = 'create_waiver -id {{TIMING-3}} -scope -timestamp "{}"'
        self.assertEqual(constraints_digest(waiver.format('one')),
                         constraints_digest(waiver.format('two')))
        self.assertNotEqual(constraints_digest(waiver.format('one')),
                            constraints_digest('create_waiver -id {TIMING-4} -scope -timestamp "one"'))
        baseline = 'current_instance cpm\nset_case_analysis 0 [get_pins RXUSRCLK]\n'
        hpu_loc = 'set_property LOC SLICE_X337Y792 [get_cells {hpu_3parts/core/replica}]\n'
        self.assertEqual(constraints_digest(baseline), constraints_digest(baseline + hpu_loc))
        cpm_loc = 'set_property LOC SLICE_X337Y792 [get_cells {cpm/inst/replica}]\n'
        self.assertNotEqual(constraints_digest(baseline), constraints_digest(baseline + cpm_loc))
