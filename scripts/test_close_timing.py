"""Bounded hold-repair selection and Tcl orchestration regressions."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'versal/scripts'))
import repair_metrics as metrics

BASE = dict(legal=True, wns=-.002, tns=-.092, whs=-.021, ths=-1.04,
            setup_failing=87, hold_failing=99, wpws=0, tpws=0, pulse_failing=0,
            setup_total=1000, hold_total=1000, pulse_total=1000)
PASS = dict(BASE, wns=.001, tns=0, setup_failing=0, whs=.001, ths=0, hold_failing=0)
HOLD_PASS = dict(PASS, wns=-.01, tns=-1, setup_failing=5)


class SelectionTests(unittest.TestCase):
    def test_hold_repair_can_cost_setup_slack(self):
        self.assertTrue(metrics.eligible(HOLD_PASS))
        self.assertFalse(metrics.timing_pass(HOLD_PASS))
        self.assertFalse(metrics.eligible(BASE))
        self.assertTrue(metrics.timing_pass(PASS))

    def test_negative_numeric_slack_and_invalid_results(self):
        for change in [dict(whs=-.000001), dict(legal=False), dict(hold_failing=1),
                       dict(wpws=-.000001), dict(wns=float('nan')), dict(setup_total=0)]:
            self.assertFalse(metrics.eligible(dict(PASS, **change)))
        self.assertFalse(metrics.timing_pass(dict(PASS, wns=-.000001)))

    def test_ranking_and_stable_ties(self):
        data = dict(first=HOLD_PASS, second=dict(HOLD_PASS, tns=-.1), bad=BASE)
        with patch.object(metrics, 'read', side_effect=data.__getitem__):
            self.assertEqual(metrics.select(['bad', 'first', 'second']), 'second')
            data['second'] = dict(HOLD_PASS)
            self.assertEqual(metrics.select(['first', 'second']), 'first')
            with self.assertRaises(ValueError):
                metrics.select(['bad'])


class FlowTests(unittest.TestCase):
    def run_flow(self, first, second, illegal_input=False, skip=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, data in [('hold_fix', first), ('combined', second)]:
                (root / (name + '_metrics.json')).write_text(json.dumps(data))
            script = r'''
source {HELPER}
set illegal ILLEGAL
set skip SKIP
proc mark_stage {name} {puts "STAGE $name"}
proc hpu_repair::require_legal {name} {
    global illegal
    if {$illegal && $name eq "hold_input"} {error "illegal input"}
}
proc hpu_repair::failure_paths {} {}
proc hpu_repair::snapshot {name} {close [open ${name}.dcp w]}
proc hpu_repair::optimize {name args} {
    global skip
    if {$skip} {error "$name: Vivado skipped optimization"}
    puts "OPT $name $args"
}
proc close_design {} {}
proc open_checkpoint {name} {puts "OPEN $name"}
set rc [catch {hpu_repair::close_timing} message]
puts "RESULT $rc $message"
puts "SELECTED [file exists postroute_physopt.dcp]"
'''.replace('HELPER', str(ROOT / 'versal/scripts/repair_route.tcl')).replace('ILLEGAL', str(int(illegal_input))).replace('SKIP', str(int(skip)))
            result = subprocess.run(['tclsh'], input=script, text=True, cwd=root, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            return result.stdout

    def test_early_success(self):
        output = self.run_flow(PASS, BASE)
        self.assertIn('RESULT 0', output)
        self.assertIn('OPT hold_fix -aggressive_hold_fix', output)
        self.assertNotIn('OPT combined', output)
        self.assertIn('STAGE selected_hold_fix', output)

    def test_combined_uses_hold_fixed_candidate(self):
        output = self.run_flow(HOLD_PASS, PASS)
        self.assertIn('STAGE combined_start_from_hold_fix', output)
        self.assertIn('OPT combined -directive ExploreWithAggressiveHoldFix', output)
        self.assertIn('STAGE selected_combined', output)

    def test_combined_reopens_input_after_bad_hold_or_routing(self):
        for first in [BASE, dict(PASS, legal=False)]:
            output = self.run_flow(first, PASS)
            self.assertIn('STAGE combined_start_from_hold_input', output)
            self.assertIn('RESULT 0', output)

    def test_no_eligible_candidate(self):
        output = self.run_flow(BASE, BASE)
        self.assertIn('RESULT 1', output)
        self.assertIn('SELECTED 0', output)

    def test_illegal_input_and_skipped_optimization_abort(self):
        output = self.run_flow(PASS, PASS, illegal_input=True)
        self.assertIn('RESULT 1 illegal input', output)
        self.assertNotIn('OPT ', output)
        output = self.run_flow(PASS, PASS, skip=True)
        self.assertIn('Vivado skipped optimization', output)
        self.assertIn('SELECTED 0', output)


if __name__ == '__main__':
    unittest.main()
