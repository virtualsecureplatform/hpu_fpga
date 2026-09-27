"""Replay preserves the routing command and does not perform repair/signoff."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReplayTests(unittest.TestCase):
    def replay(self, fail=False, version='Vivado v2026.1 Build 6511674'):
        with tempfile.TemporaryDirectory() as tmp:
            script = r'''
set argc 3
set argv [list input.dcp {OUTPUT} replay]
set ::env(PROJECT_DIR) {ROOT}
proc version {} {return {VERSION}}
proc set_param {name value} {puts "PARAM $name $value"}
proc open_checkpoint {name} {puts OPEN}
proc current_project {} {return project}
proc set_property {name value object} {
    if {$name ne "IP_REPO_PATHS"} {error "Unexpected constraint change"}
}
proc get_clocks {args} {return clock}
proc get_property {args} {return 2.857142857}
proc report_timing_summary {args} {puts "TIMING $args"}
proc route_design {args} {
    puts "ROUTE $args"
    if {FAIL} {error "simulated router failure"}
}
proc write_checkpoint {name} {puts "CHECKPOINT $name"}
rename exit real_exit
proc exit {code} {}
set rc [catch {source {HELPER}} message]
puts "RESULT $rc $message"
puts "COMPLETE [file exists replay.complete]"
'''.replace('OUTPUT', tmp).replace('ROOT', str(ROOT)).replace('VERSION', version).replace('FAIL', str(int(fail))).replace('HELPER', str(ROOT / 'versal/scripts/replay_route_crash.tcl'))
            result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True, cwd=tmp)
            self.assertEqual(result.stderr, '')
            return result.stdout

    def test_same_route_command_without_optimization(self):
        output = self.replay()
        self.assertIn('PARAM general.maxThreads 8', output)
        self.assertIn('ROUTE -directive AggressiveExplore', output)
        self.assertLess(output.index('TIMING '), output.index('ROUTE '))
        self.assertIn('CHECKPOINT routed.dcp', output)
        self.assertIn('COMPLETE 1', output)

    def test_failure_does_not_create_completion_or_checkpoint(self):
        output = self.replay(fail=True)
        self.assertIn('RESULT 1 simulated router failure', output)
        self.assertIn('COMPLETE 0', output)
        self.assertNotIn('CHECKPOINT ', output)

    def test_wrong_tool_build_rejected_before_loading_input(self):
        output = self.replay(version='Vivado v2026.1 Build 9999999')
        self.assertIn('RESULT 1 Replay requires the original Vivado', output)
        self.assertNotIn('OPEN', output)
