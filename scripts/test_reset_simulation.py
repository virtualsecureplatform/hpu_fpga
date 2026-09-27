"""Run the focused asynchronous-reset test on the installed Vivado simulator."""
from pathlib import Path
import shutil
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


IVERILOG = os.environ.get('HPU_IVERILOG', shutil.which('iverilog'))
@unittest.skipUnless(IVERILOG or all(shutil.which(tool) for tool in ('xvlog', 'xelab', 'xsim')), 'No HDL simulator available')
class ResetSimulationTests(unittest.TestCase):
    def test_assertion_release_mask_and_stopped_clock(self):
        with tempfile.TemporaryDirectory(prefix='hpu-reset-sim-') as directory:
            commands = [
                ['xvlog', '--sv', str(ROOT / 'versal/rtl/hpu_pcie_reset_sync.sv'), str(ROOT / 'scripts/tb_pcie_reset_sync.sv')],
                ['xelab', 'tb_pcie_reset_sync', '-s', 'reset_test'],
                ['xsim', 'reset_test', '-R'],
            ]
            if IVERILOG:
                compiler = [IVERILOG]
                if os.environ.get('HPU_IVERILOG_LIB'):
                    compiler += ['-B', os.environ['HPU_IVERILOG_LIB']]
                commands = [compiler + ['-g2012', '-s', 'tb_pcie_reset_sync', '-o', 'reset.vvp',
                            str(ROOT / 'versal/rtl/hpu_pcie_reset_sync.sv'), str(ROOT / 'scripts/tb_pcie_reset_sync.sv')],
                            [str(Path(IVERILOG).with_name('vvp')), 'reset.vvp']]
            for command in commands:
                result = subprocess.run(command, cwd=directory, text=True, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('RESET_SIMULATION_PASSED', result.stdout)
