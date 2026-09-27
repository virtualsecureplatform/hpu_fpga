"""Exercise bounded repair control flow without loading a multi-GB checkpoint."""
from pathlib import Path
import subprocess
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'versal/scripts'))
import repair_metrics as metrics


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.best = dict(legal=True, wns=-.034, tns=-43.09, whs=0,
                         hold_failing=0, wpws=0, pulse_failing=0,
                         setup_total=100, hold_total=100, pulse_total=100)

    def test_numeric_slack_and_actual_route_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp) / 'candidate'
            Path(str(stage) + '_timing.rpt').write_text(
                'WNS(ns) TNS(ns) WHS(ns) THS(ns) WPWS(ns) TPWS(ns)\n'
                '-------\n0.000 0.000 0 100 0.000 0.000 0 100 0.000 0.000 0 100\n')
            Path(str(stage) + '_numeric.json').write_text(json.dumps(dict(legal=1, wns=-.00001, whs=0)))
            route = Path(str(stage) + '_route.rpt')
            route.write_text('Routable nets : 100 :\nFully routed nets : 100 :\nNets with routing errors : 0 :\n')
            result = metrics.extract(stage)
            self.assertTrue(result['legal'])
            self.assertEqual(result['wns'], -.00001)
            route.write_text('Routable nets : 100 :\nFully routed nets : 99 :\nNets with routing errors : 1 :\n')
            self.assertFalse(metrics.extract(stage)['legal'])

    def test_expected_input_and_wrong_endpoint(self):
        net = 'hpu_3parts/p3_p2_sll/in_pipe/out_data[6244]'
        endpoint = 'hpu_3parts/p3_p2_sll/out_pipe/depth1.out_data_reg[6244]/D'
        report = ('Routable nets : 100 :\nFully routed nets : 99 :\n'
                  'Nets with routing errors : 1 :\n'
                  f'  {net}\n    Unrouted Pin:\n      {endpoint}\n')
        metrics.validate_input(report, net, endpoint)
        for bad in (report.replace(endpoint, 'other/D'), report.replace('errors : 1', 'errors : 2')):
            with self.assertRaises(ValueError):
                metrics.validate_input(bad, net, endpoint)

    def test_improvement_and_equal_candidate(self):
        self.assertTrue(metrics.acceptable(self.best, self.best))
        self.assertTrue(metrics.acceptable(self.best, dict(self.best, wns=-.01, tns=-10)))

    def test_invalid_or_regressing_candidates(self):
        for change in [dict(legal=False), dict(whs=-.00001), dict(hold_failing=1),
                       dict(wpws=-.001), dict(pulse_failing=1), dict(wns=-.035),
                       dict(tns=-44), dict(setup_total=0)]:
            with self.subTest(change=change):
                self.assertFalse(metrics.acceptable(self.best, dict(self.best, **change)))


class RepairFlowTests(unittest.TestCase):
    def run_flow(self, scenario):
        with tempfile.TemporaryDirectory() as tmp:
            script = r'''
source {HELPER}
set scenario SCENARIO
set target {hpu_3parts/p3_p2_sll/in_pipe/out_data[6244]}
set endpoint {hpu_3parts/p3_p2_sll/out_pipe/depth1.out_data_reg[6244]/D}
set routed 0
set calls {}
proc report_route_status {args} {
    global routed target scenario endpoint
    if {[lsearch $args -boolean_check] >= 0} {
        if {[lindex $args end] eq "ROUTED_FULLY"} { return $routed }
        return [expr {!$routed}]
    }
    if {[lsearch $args -return_nets] >= 0} {
        if {[lindex $args end] eq "PARTIAL"} {
            if {$scenario eq "unexpected"} {return other}
            return [list $target]
        }
        return {}
    }
    return {}
}
proc get_nets {args} {
    global target
    if {[lsearch $args -of_objects] < 0 && [lindex $args end] ne [format {NAME == "%s"} $target]} {
        error "Net lookup must use literal equality"
    }
    if {[lsearch $args -segments] >= 0} {return [list alias_segment $target]}
    return [list $target]
}
proc get_pins {args} {
    global endpoint
    if {[lindex $args end] ne [format {NAME == "%s"} $endpoint]} {error "Pin lookup must use literal equality"}
    return [list $endpoint]
}
proc get_property {property object} {return $object}
proc report_timing_summary {args} {}
proc report_property {args} {}
proc mark_stage {stage} {puts "STAGE $stage"}
proc route_design {args} {
    global calls routed scenario
    lappend calls $args
    if {[lsearch $args -auto_delay] >= 0 && $scenario eq "success"} {set routed 1}
    if {[lsearch $args -preserve] >= 0 && $scenario eq "fallback"} {set routed 1}
}
proc close_design {} {}
proc open_checkpoint {args} {}
close [open vivado.log w]
set skip_count 0
proc phys_opt_design {args} {
    global scenario skip_count
    if {$scenario eq "skipped"} {
        # Exercise Vivado's Tcl-message case where counters stay unchanged.
        set f [open vivado.log a]
        puts $f "WARNING: Skipping post-route optimization"
        close $f
    }
}
proc get_msg_config {args} {global skip_count; return $skip_count}

rename exec real_exec
proc exec {args} {
    switch [lindex $args 2] {
        input {return {}}
        compare {return accept}
        setup_pass {return yes}
        default {error "Unexpected exec $args"}
    }
}
rename hpu_repair::snapshot hpu_repair::real_snapshot
proc hpu_repair::snapshot {stage} {close [open ${stage}.dcp w]}
if {$scenario eq "skipped"} {
    set routed 1
    set rc [catch {hpu_repair::optimize test -directive Explore} message]
} else {
    set rc [catch {hpu_repair::run} message]
}
puts "RESULT $rc $message"
puts "CALLS $calls"
'''.replace('HELPER', str(ROOT / 'versal/scripts/repair_route.tcl')).replace('SCENARIO', scenario)
            result = subprocess.run(['tclsh'], input=script, text=True, cwd=tmp, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(result.stderr, result.stderr)
            return result.stdout

    def test_exact_bus_lookup_and_success(self):
        result = self.run_flow('success')
        self.assertIn('RESULT 0', result)
        self.assertNotIn('-preserve', result)
        self.assertIn('STAGE explore_accept', result)

    def test_unexpected_net_aborts_before_mutation(self):
        result = self.run_flow('unexpected')
        self.assertIn('RESULT 1 Unexpected defective net set', result)
        self.assertIn('CALLS \n', result)

    def test_single_fallback_succeeds(self):
        result = self.run_flow('fallback')
        self.assertIn('RESULT 0', result)
        self.assertEqual(result.count('-preserve'), 1)

    def test_fallback_exhaustion_blocks_optimization(self):
        result = self.run_flow('failed')
        self.assertIn('RESULT 1 repaired: design is not legally routed', result)
        self.assertEqual(result.count('-preserve'), 1)
        self.assertNotIn('STAGE explore', result)

    def test_skipped_optimization_is_failure(self):
        self.assertIn('RESULT 1 test: Vivado skipped optimization', self.run_flow('skipped'))


if __name__ == '__main__':
    unittest.main()
