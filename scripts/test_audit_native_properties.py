from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent


class PropertyTests(unittest.TestCase):
    def ground(self, properties, value='', net_type='SIGNAL'):
        script = f'''
source {{{ROOT}/versal/scripts/constraint_audit.tcl}}
proc get_nets {{args}} {{return net}}
proc list_property {{args}} {{return {{{properties}}}}}
proc get_property {{name net}} {{
    if {{$name eq "TYPE"}} {{return {{{net_type}}}}}
    return {{{value}}}
}}
puts [hpu_audit::ground pin]
'''
        result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
        self.assertEqual(result.stderr, '')
        return result.stdout.strip()

    def test_absent_property_is_unknown(self):
        self.assertEqual(self.ground('TYPE'), 'net 0')

    def test_empty_or_malformed_boolean_is_unknown(self):
        for value in ('', 'unknown', '0', 'false'):
            self.assertEqual(self.ground('TYPE IS_GND', value), 'net 0')

    def test_affirmative_ground_evidence(self):
        self.assertEqual(self.ground('TYPE', net_type='GROUND'), 'net 1')
        self.assertEqual(self.ground('IS_GND', 'true'), 'net 1')

    def test_reset_exception_is_exact_and_fails_closed(self):
        for valid in (True, False):
            script = f'''
source {{{ROOT}/versal/scripts/pcie_reset_constraints.tcl}}
proc get_cells {{args}} {{return [list [lindex $args end]]}}
proc get_property {{args}} {{return {int(valid)}}}
proc get_pins {{args}} {{
    if {{[lindex $args end] ne "REF_PIN_NAME == CLR && DIRECTION == IN"}} {{error "Overbroad pin query"}}
    return [list [lindex $args 1]/CLR]
}}
proc set_false_path {{option pins}} {{
    if {{$option ne "-to" || [llength $pins] != 4}} {{error "Overbroad exception"}}
    puts EXACT_FOUR_CLEAR_PINS
}}
puts [catch {{hpu_reset::constrain}} message]
puts $message
'''
            result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
            self.assertEqual(result.stderr, '')
            if valid:
                self.assertIn('EXACT_FOUR_CLEAR_PINS', result.stdout)
            else:
                self.assertNotIn('EXACT_FOUR_CLEAR_PINS', result.stdout)
                self.assertIn('not ASYNC_REG', result.stdout)
