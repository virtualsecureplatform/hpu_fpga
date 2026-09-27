"""Check clock preflight rejection and shared reset-domain connectivity."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ClockTests(unittest.TestCase):
    def window_from_regions(self, regions, fabric=None):
        script = 'source {' + str(ROOT / 'versal/scripts/clock_signoff.tcl') + '}\n'
        script += 'proc get_slrs {args} {return {SLR0 SLR1 SLR2}}\n'
        script += 'proc get_sites {args} {return slices}\n'
        script += 'proc get_clock_regions {args} {if {[lindex $args 1] eq "slices"} {return {' + ' '.join(regions if fabric is None else fabric) + '}}; return {' + ' '.join(regions) + '}}\n'
        script += 'puts [catch {hpu_clock::full_window} message]\nputs $message\n'
        result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
        self.assertEqual(result.stderr, '')
        return result.stdout

    def test_native_region_fixture(self):
        # Actual V80 region widths returned by Vivado 2026.1.
        regions = [f'X{x}Y{y}' for y in range(12)
                   for x in range(13 if y == 0 else 9 if y == 11 else 10)]
        fabric = [f'X1Y{y}' for y in range(1, 11)]
        self.assertEqual(self.window_from_regions(regions, fabric),
                         '0\nCLOCKREGION_X0Y1:CLOCKREGION_X9Y10\n')

    def test_rectangular_device_keeps_full_width(self):
        self.assertEqual(self.window_from_regions(['X0Y0', 'X1Y0', 'X0Y1', 'X1Y1']),
                         '0\nCLOCKREGION_X0Y0:CLOCKREGION_X1Y1\n')

    def test_missing_row_is_rejected(self):
        self.assertIn('1\nMissing clock-region row Y1',
                      self.window_from_regions(['X0Y0', 'X0Y2']))

    def test_disjoint_columns_are_rejected(self):
        self.assertIn('1\nNo full-height clock-region columns',
                      self.window_from_regions(['X0Y0', 'X1Y1']))

    def test_column_holes_are_rejected(self):
        self.assertIn('1\nFull-height clock-region columns are not contiguous',
                      self.window_from_regions(['X0Y0', 'X2Y0', 'X0Y1', 'X2Y1']))

    def test_missing_regions_are_rejected(self):
        self.assertIn('1\nMissing fabric clock regions', self.window_from_regions([]))

    def run_clock(self, configure=True, bad_drc=False, missing=False, bad_rule='NTCN-16'):
        script = r'''
source {HELPER}
set missing MISSING
set bad_drc BAD_DRC
array set props {USER_CLOCK_EXPANSION_WINDOW CLOCKREGION_X0Y2:CLOCKREGION_X9Y9 GCLK_DESKEW CALIBRATED}
proc get_pins {args} {global missing; if {$missing} {return {}}; return bufg/O}
proc get_nets {args} {return prc_net}
proc get_slrs {args} {return {SLR0 SLR1 SLR2}}
proc get_clock_regions {args} {
    set regions {}
    if {[lindex $args 1] eq "slices"} {
        for {set y 1} {$y <= 10} {incr y} {lappend regions X1Y${y}}
        return $regions
    }
    for {set y 0} {$y <= 11} {incr y} {
        set xmax [expr {$y == 0 ? 12 : ($y == 11 ? 8 : 9)}]
        for {set x 0} {$x <= $xmax} {incr x} {lappend regions X${x}Y${y}}
    }
    return $regions
}
proc get_sites {args} {return slices}
proc list_property {args} {return {USER_CLOCK_ROOT USER_CLOCK_TRACK USER_CLOCK_VTREE_TYPE}}
proc reset_property {name net} {error "Unsupported native clock-property reset"}
proc set_property {name value net} {global props; set props($name) $value; puts "SET $name $value"}
proc get_property {name net} {global props; return $props($name)}
proc report_property {args} {}
proc get_drc_checks {args} {return {NTCN-16 NTCN-17}}
proc report_drc {args} {puts DRC}
proc get_drc_violations {pattern} {
    if {$pattern ne "NTCN-16* NTCN-17*"} {error "Unexpected DRC query $pattern"}
    global bad_drc; if {$bad_drc} {return {BAD_RULE#1}}; return {}
}
set rc [catch {
    if {CONFIGURE} {hpu_clock::configure}
    hpu_clock::validate validation
} message]
puts "RESULT $rc $message"
puts "MARKER [file exists validation/clock_validation.json]"
'''.replace('HELPER', str(ROOT / 'versal/scripts/clock_signoff.tcl')).replace('MISSING', str(int(missing))).replace('BAD_DRC', str(int(bad_drc))).replace('BAD_RULE', bad_rule).replace('CONFIGURE', str(int(configure)))
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['tclsh'], input=script, cwd=directory, text=True, capture_output=True)
        self.assertEqual(result.stderr, '')
        return result.stdout

    def test_full_slr_window_and_complete_explicit_tuple(self):
        output = self.run_clock()
        self.assertIn('RESULT 0', output)
        self.assertIn('SET USER_CLOCK_ROOT ', output)
        self.assertIn('SET USER_CLOCK_TRACK -1', output)
        self.assertIn('SET USER_CLOCK_ROOT X5Y7', output)
        self.assertIn('SET USER_CLOCK_TRACK 7', output)
        self.assertIn('SET USER_CLOCK_VTREE_TYPE ', output)
        self.assertIn('MARKER 1', output)
        self.assertIn('SET USER_CLOCK_EXPANSION_WINDOW CLOCKREGION_X0Y1:CLOCKREGION_X9Y10', output)
        self.assertNotIn('CLOCKREGION_X12Y11', output)

    def test_partial_window_rejected_without_changing_constraints(self):
        output = self.run_clock(configure=False)
        self.assertIn('RESULT 1 Processing clock must cover complete SLRs', output)
        self.assertNotIn('SET USER_CLOCK_ROOT', output)
        self.assertNotIn('DRC', output)
        self.assertIn('MARKER 0', output)

    def test_native_drc_failure_prevents_marker(self):
        output = self.run_clock(bad_drc=True)
        self.assertIn('RESULT 1 Clock topology failed DRC', output)
        self.assertIn('MARKER 0', output)

    def test_missing_clock_is_rejected(self):
        self.assertIn('RESULT 1 Expected one processing BUFG', self.run_clock(missing=True))

    def test_incomplete_tuple_drc_prevents_marker(self):
        output = self.run_clock(bad_drc=True, bad_rule='NTCN-17')
        self.assertIn('Clock topology failed DRC: NTCN-17#1', output)
        self.assertIn('MARKER 0', output)


class BlockDesignTests(unittest.TestCase):
    def test_configuration_domains_share_reset_and_pcie_masks_after_sync(self):
        script = r'''
source {HELPER}
namespace eval _nsp_hpu {
    variable USER_0_FREQ 350; variable USER_1_FREQ 100
    variable MHDMA_FREERUN_FREQ 100; variable MRMAC_APB3_FREQ 200; variable MHDMA_FREQ 390.625
}
set ::env(PROJECT_DIR) {ROOT}
proc check_parent_hier {args} {return /}
proc current_bd_instance {args} {return /}
proc create_bd_cell {args} {puts "CELL $args"; return [lindex $args end]}
proc create_bd_pin {args} {}
proc create_bd_intf_pin {args} {}
proc connect_bd_intf_net {args} {}
proc get_bd_intf_pins {args} {return $args}
proc get_bd_pins {args} {return $args}
proc set_property {args} {}
proc add_files {args} {}
proc connect_bd_net {args} {puts "NET $args"}
create_hier_cell_clock_reset / clock_reset
'''.replace('HELPER', str(ROOT / 'versal/scripts/bd/bd_clock_reset.tcl')).replace('ROOT', str(ROOT))
        result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
        self.assertEqual(result.stderr, '')
        self.assertNotIn('mhdma_freerun_psr', result.stdout)
        self.assertIn('usr_1_psr/interconnect_aresetn resetn_usr_1_ic resetn_mhdma_cfg_ic', result.stdout)
        self.assertIn('resetn_synchronized reset_sync/resetn_out inv/Op1', result.stdout)
        self.assertIn('resetn_in_1 resetn_in reset_sync/resetn_in', result.stdout)
