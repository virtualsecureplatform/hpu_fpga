"""The signoff-only recovery branch never mutates the routed design."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class SignoffOnlyTests(unittest.TestCase):
    def test_preserves_checkpoint_and_skips_implementation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checkpoint = root / 'input.dcp'
            checkpoint.write_bytes(b'original checkpoint')
            script = r'''
set argc 3
set argv [list {CHECKPOINT} {OUTPUT} signoff]
set ::env(PROJECT_DIR) {ROOT}
proc set_param {args} {}
proc open_checkpoint {args} {}
proc current_project {} {return project}
proc set_property {name args} {
    if {$name ne "IP_REPO_PATHS"} {error "Unexpected design mutation"}
}
proc get_clocks {args} {return clk}
proc get_property {args} {return 2.857142857}
rename source native_source
proc source {args} {
    set filename [lindex $args end]
    if {[file tail $filename] eq "timing_signoff.tcl"} {
        namespace eval hpu_signoff {}
        proc hpu_signoff::run {directory checkpoint} {puts "SIGNOFF $checkpoint"}
    } else {uplevel 1 [list native_source {*}$args]}
}
rename exit real_exit
proc exit {args} {}
source {HELPER}
'''.replace('CHECKPOINT', str(checkpoint)).replace('OUTPUT', str(root / 'out')).replace('ROOT', str(ROOT)).replace('HELPER', str(ROOT / 'versal/scripts/recover_route.tcl'))
            result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
            self.assertEqual(result.stderr, '')
            self.assertIn('SIGNOFF ', result.stdout)
            self.assertEqual((root / 'out/postroute_physopt.dcp').read_bytes(), checkpoint.read_bytes())
            self.assertTrue((root / 'out/recovery.complete').exists())
