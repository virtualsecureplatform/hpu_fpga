"""Bounded route finalization and checkpoint selection regressions."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_close_timing import BASE, HOLD_PASS, PASS, ROOT


class FinishRouteTests(unittest.TestCase):
    def run_flow(self, first, second, unexpected=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, data in [('preserved', first), ('full_route', second)]:
                (root / (name + '_metrics.json')).write_text(json.dumps(data))
            script = r'''
source {HELPER}
set unexpected UNEXPECTED
proc mark_stage {name} {puts "STAGE $name"}
proc hpu_repair::verify_input {expected endpoint prefix} {
    global unexpected
    if {$unexpected} {error "Unexpected defective net set"}
    if {$expected ne {hpu_3parts/p2_p1_sll/in_pipe/out_data[5862]_hold_fix_1}} {error "Wrong net"}
    if {$endpoint ne {hpu_3parts/p2_p1_sll/out_pipe/depth1.out_data_reg[5862]/D}} {error "Wrong endpoint"}
}
proc hpu_repair::failure_paths {} {}
proc hpu_repair::snapshot {name} {close [open ${name}.dcp w]}
proc hpu_repair::require_legal {name} {}
proc route_design {args} {puts "ROUTE $args"}
proc phys_opt_design {args} {error "Unexpected physical optimization pass"}
proc close_design {} {}
proc open_checkpoint {name} {puts "OPEN $name"}
set rc [catch {hpu_repair::finish_route} message]
puts "RESULT $rc $message"
puts "SELECTED [file exists postroute_physopt.dcp]"
'''.replace('HELPER', str(ROOT / 'versal/scripts/repair_route.tcl')).replace('UNEXPECTED', str(int(unexpected)))
            result = subprocess.run(['tclsh'], input=script, text=True, cwd=root, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            return result.stdout

    def test_first_pass_success_skips_full_route(self):
        output = self.run_flow(PASS, BASE)
        self.assertIn('ROUTE -preserve -directive AggressiveExplore -tns_cleanup', output)
        self.assertEqual(output.count('ROUTE '), 1)
        self.assertIn('STAGE selected_preserved', output)
        self.assertIn('RESULT 0', output)

    def test_hold_failure_never_triggers_full_unroute(self):
        output = self.run_flow(BASE, PASS)
        self.assertNotIn('ROUTE -unroute', output)
        self.assertEqual(output.count('ROUTE '), 1)
        self.assertIn('RESULT 1', output)
        self.assertIn('SELECTED 0', output)

    def test_successful_route_command_with_illegal_result_is_rejected(self):
        output = self.run_flow(dict(PASS, legal=False), PASS)
        self.assertNotIn('ROUTE -unroute', output)
        self.assertIn('RESULT 1', output)
        self.assertIn('SELECTED 0', output)

    def test_failure_stops_after_one_preserving_attempt(self):
        output = self.run_flow(dict(BASE, legal=False), BASE)
        self.assertEqual(output.count('ROUTE '), 1)
        self.assertIn('RESULT 1', output)
        self.assertIn('SELECTED 0', output)

    def test_retains_first_eligible_candidate_when_fallback_worsens(self):
        output = self.run_flow(HOLD_PASS, dict(HOLD_PASS, wns=-.02))
        self.assertIn('STAGE selected_preserved', output)

    def test_unexpected_input_prevents_routing(self):
        output = self.run_flow(PASS, PASS, unexpected=True)
        self.assertIn('RESULT 1 Unexpected defective net set', output)
        self.assertNotIn('ROUTE ', output)
        self.assertIn('SELECTED 0', output)


if __name__ == '__main__':
    unittest.main()
