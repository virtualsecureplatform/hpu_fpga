"""Inspection must capture all 64 pins without changing implementation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class InspectTests(unittest.TestCase):
    def run_inspection(self, missing=False):
        with tempfile.TemporaryDirectory() as tmp:
            script = r'''
set argc 3
set argv [list input.dcp {OUTPUT} gt-inspect]
proc version {} {return test}
proc set_param {name value} {puts "PARAM $name $value"}
proc open_checkpoint {name} {puts OPEN}
proc update_timing {} {puts UPDATE}
proc get_pins {args} {
    if {MISSING} {return {}}
    if {"-leaf" in $args} {return CPM/driver}
    return [lindex $args end]
}
proc report_property {args} {return {CASE_VALUE 0}}
proc get_clocks {args} {return {}}
proc get_nets {args} {return net}
proc get_cells {args} {return CPM}
proc get_property {args} {return CPM5}
proc check_timing {args} {puts CHECK}
proc write_xdc {args} {puts EXPORT}
rename exit real_exit
proc exit {code} {}
set rc [catch {source {HELPER}} message]
puts "RESULT $rc $message"
puts "COMPLETE [file exists gt_inspect.complete]"
'''.replace('OUTPUT', tmp).replace('MISSING', str(int(missing))).replace(
                'HELPER', str(ROOT / 'versal/scripts/inspect_gt_endpoints.tcl'))
            result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
            self.assertEqual(result.stderr, '')
            evidence = Path(tmp, 'gt_native_evidence.txt').read_text()
            return result.stdout, evidence

    def test_read_only_capture(self):
        output, evidence = self.run_inspection()
        self.assertIn('COMPLETE 1', output)
        self.assertIn('PARAM general.maxThreads 8', output)
        self.assertLess(output.index('UPDATE'), output.index('CHECK'))
        self.assertEqual(sum(line.startswith('PIN ') for line in evidence.splitlines()), 64)
        self.assertEqual(evidence.count('DRIVER_PRIMITIVE CPM5'), 64)

    def test_missing_pin_fails_closed(self):
        output, _ = self.run_inspection(missing=True)
        self.assertIn('RESULT 1 Missing or ambiguous endpoint', output)
        self.assertIn('COMPLETE 0', output)
        self.assertNotIn('EXPORT', output)
