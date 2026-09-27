"""Image metadata must be complete, exact, and match the UUID manifest."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'versal/scripts'))
from constraint_audit import UUID_CELL, image_constraints, constraints_digest


class ImageMetadataTests(unittest.TestCase):
    def setUp(self):
        self.uuid = '0123456789abcdef1020304050607080'
        self.manifest = f'logic_uuid {self.uuid} interface_uuid ' + '0' * 32
        words = [int(self.uuid[i:i+8], 16) for i in range(0, 32, 8)][::-1]
        self.lines = ['create_property INIT cell -type string', 'current_instance -quiet']
        for i in range(32):
            value = sum(((word >> i) & 1) << j for j, word in enumerate(words))
            self.lines.append(f"set_property INIT 32'h{value:08X} [get_cells {UUID_CELL}{i}_{i}]")
        self.lines.append('set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]')

    def test_exact_metadata(self):
        text, uuid = image_constraints('\n'.join(self.lines), self.manifest)
        self.assertEqual(text, 'current_instance -quiet')
        self.assertEqual(uuid, self.uuid)

    def test_missing_duplicate_wrong_cell_and_timestamp(self):
        variants = [self.lines[:2] + self.lines[3:], self.lines + [self.lines[2]],
                    self.lines + [self.lines[0]], self.lines + [self.lines[-1]],
                    [line.replace(UUID_CELL, 'other/') for line in self.lines],
                    [line.replace('TIMESTAMP', '0') for line in self.lines]]
        for lines in variants:
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                image_constraints('\n'.join(lines), self.manifest)

    def test_wrong_uuid_manifest(self):
        with self.assertRaisesRegex(ValueError, 'contents do not match'):
            image_constraints('\n'.join(self.lines), self.manifest.replace(self.uuid, '0' * 32))

    def test_other_constraints_are_not_discarded(self):
        for extra in ('set_false_path -to other', 'current_instance other',
                      'set_case_analysis 1 [get_pins clock]',
                      "set_property INIT 32'h00000000 [get_cells unrelated]"):
            text, _ = image_constraints('\n'.join(self.lines + [extra]), self.manifest)
            self.assertNotEqual(constraints_digest(text), constraints_digest('current_instance -quiet'))

    def test_malformed_manifest(self):
        with self.assertRaises(ValueError):
            image_constraints('\n'.join(self.lines), self.manifest + '; command')
