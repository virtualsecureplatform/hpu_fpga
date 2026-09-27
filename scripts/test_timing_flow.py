"""Regression checks for fail-closed timing acceptance and launcher failures."""
import importlib.util
import json
import runpy
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'versal/scripts'))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


gate = module('gate', 'versal/scripts/check_timing_signoff.py')
runner = module('runner', 'scripts/run_timing_build.py')
extract = module('extract', 'versal/scripts/complete_signoff_checks.py')


class FollowupTests(unittest.TestCase):
    def test_failed_recovery_signoff_does_not_launch_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'systemd_unit').write_text('test.service')
            (root / 'status.json').write_text('{"state": "complete"}')
            (root / 'recovery.complete').touch()
            with patch.object(sys, 'argv', ['finish_timing_image.py', str(root), str(root / 'image')]), \
                 patch('subprocess.run', return_value=Mock(returncode=3)) as command:
                with self.assertRaisesRegex(SystemExit, 'Routing signoff did not pass'):
                    runpy.run_path(str(ROOT / 'scripts/finish_timing_image.py'), run_name='__main__')
                self.assertEqual(command.call_count, 1)
                self.assertEqual(command.call_args.args[0][:3], ['systemctl', '--user', 'is-active'])


class SignoffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ('route', 'bus_skew', 'drc', 'methodology', 'cdc', 'clocks', 'exceptions'):
            (self.root / f'{name}.rpt').write_text('fixture report\n')
        (self.root / 'route.rpt').write_text('Routable nets : 100\nFully routed nets : 100\nNets with routing errors : 0\n')
        (self.root / 'bus_skew.rpt').write_text('Bus Skew Report\nSlack (MET) : 0.100ns\n')
        (self.root / 'drc.rpt').write_text('Report DRC\nChecks found: 0\n')
        (self.root / 'methodology.rpt').write_text('Report Methodology\nChecks found: 0\n')
        (self.root / 'cdc.rpt').write_text('CDC Report\nCDC-3 Info 10 1-bit synchronized\n')
        self.timing = ('WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints '
                       'WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints '
                       'WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints\n'
                       '-------\n0.010 0.000 0 100 0.001 0.000 0 100 0.020 0.000 0 100\n')
        self.timing += '\n'.join(f'checking {name} (0)' for name in ('no_clock', 'multiple_clock', 'unconstrained_internal_endpoints', 'no_input_delay', 'no_output_delay'))
        (self.root / 'timing.rpt').write_text(self.timing)
        (self.root / 'check_timing.rpt').write_text(self.timing)
        (self.root / 'clock_validation.json').write_text('{"passed": true}')
        (self.root / 'clock_properties.rpt').write_text('GCLK_DESKEW CALIBRATED\n')
        (self.root / 'clock_drc.rpt').write_text('Report DRC\nChecks found: 0\n')
        self.checkpoint = self.root / 'candidate.dcp'
        self.checkpoint.write_bytes(b'test checkpoint')
        gate.record_checkpoint(self.root, self.checkpoint)
        self.checks = {name: 0 for name in ('setup_paths', 'hold_paths', 'routing_errors', 'unrouted_nets', 'drc_errors', 'methodology_errors', 'cdc_critical', 'bus_skew_violations')}
        self.checks.update(processing_mhz=350, free_running_mhz=350)
        self.save()

    def save(self):
        (self.root / 'checks.json').write_text(json.dumps(self.checks))

    def test_pass(self):
        self.assertTrue(gate.check(self.root)['passed'])

    def test_changed_checkpoint_blocks_image(self):
        self.checkpoint.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Checkpoint'):
            gate.check(self.root)

    def test_changed_passing_report_invalidates_existing_signature(self):
        (self.root / 'signoff.json').write_text(json.dumps(gate.check(self.root)))
        gate.verify_signed(self.root, self.checkpoint)
        (self.root / 'timing.rpt').write_text(self.timing.replace('0.010', '0.020'))
        with self.assertRaisesRegex(ValueError, 'evidence changed'):
            gate.verify_signed(self.root, self.checkpoint)

    def test_reports_all_independent_failures(self):
        (self.root / 'timing.rpt').write_text(self.timing.replace('0.010', '-0.100'))
        (self.root / 'cdc.rpt').write_text('CDC Report\nCDC-10 Critical 1 combinational logic\n')
        with self.assertRaises(ValueError) as error:
            gate.check(self.root)
        self.assertIn('wns is negative', str(error.exception))
        self.assertIn('cdc_critical', str(error.exception))

    def test_detailed_timing_is_required_and_checked(self):
        (self.root / 'check_timing.rpt').write_text(self.timing.replace('no_clock (0)', 'no_clock (1)'))
        with self.assertRaisesRegex(ValueError, 'check_timing.rpt'):
            gate.check(self.root)
        (self.root / 'check_timing.rpt').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing or empty report'):
            gate.check(self.root)

    def test_clock_drc_cannot_be_hidden_by_marker(self):
        (self.root / 'clock_drc.rpt').write_text('Report DRC\n| NTCN-16 | Error | Invalid topology | 1 |\n')
        with self.assertRaisesRegex(ValueError, 'Clock topology'):
            gate.check(self.root)

    def test_vivado_route_table(self):
        (self.root / 'route.rpt').write_text(
            'Design Route Status\n'
            '       # of routable nets..................... :     2886115 :\n'
            '           # of fully routed nets............. :     2886115 :\n'
            '       # of nets with routing errors.......... :           0 :\n')
        self.assertTrue(gate.check(self.root)['passed'])
        text = (self.root / 'route.rpt').read_text()
        (self.root / 'route.rpt').write_text(text.replace('fully routed nets............. :     2886115',
                                                               'fully routed nets............. :     2886114'))
        with self.assertRaises(ValueError):
            gate.check(self.root)

    def test_each_failure_blocks_image(self):
        for name in ('setup_paths', 'hold_paths', 'processing_mhz', 'free_running_mhz'):
            with self.subTest(check=name):
                old = self.checks[name]
                self.checks[name] = 1
                self.save()
                with self.assertRaises(ValueError):
                    gate.check(self.root)
                self.checks[name] = old
        self.save()

    def test_negative_and_empty_timing(self):
        for value in ('-0.001', 'nan', 'bad'):
            (self.root / 'timing.rpt').write_text(self.timing.replace('0.010', value))
            with self.assertRaises(ValueError):
                gate.check(self.root)

    def test_nonfinite_clock(self):
        for value in (float('nan'), float('inf')):
            self.checks['processing_mhz'] = value
            self.save()
            with self.assertRaises(ValueError):
                gate.check(self.root)

    def test_missing_report(self):
        (self.root / 'bus_skew.rpt').unlink()
        with self.assertRaises(ValueError):
            gate.check(self.root)

    def test_unconstrained_path(self):
        (self.root / 'timing.rpt').write_text(self.timing.replace('no_clock (0)', 'no_clock (1)'))
        with self.assertRaises(ValueError):
            gate.check(self.root)

    def test_unknown_extraction_format(self):
        (self.root / 'route.rpt').write_text('Unknown format')
        with self.assertRaises(ValueError):
            extract.complete(self.root)

    def test_changed_reports_reject_stale_checks(self):
        for report, text in [('route', 'Routable nets : 100\nFully routed nets : 99\nNets with routing errors : 0\n'),
                             ('bus_skew', 'Bus Skew Report\nSlack (VIOLATED) : -0.001ns\n'),
                             ('cdc', 'CDC Report\nCDC-1 Critical 1 Unknown circuit\n'),
                             ('drc', 'Report DRC\n| Rule | Severity | Description | Checks |\n| TEST-1 | Error | bad | 1 |\n')]:
            path = self.root / f'{report}.rpt'
            old = path.read_text()
            path.write_text(text)
            with self.subTest(report=report), self.assertRaises(ValueError):
                gate.check(self.root)
            path.write_text(old)


class LauncherTests(unittest.TestCase):
    def test_synthesis_resume_selects_existing_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            (output / 'build.json').write_text(json.dumps({'repo': str(ROOT), 'vivado_root': '/unused', 'checkpoint': '/unused', 'phase': 'build', 'build_step': 'syn', 'start_memory_gib': 72}))
            (output / 'fresh.complete').touch()
            child = Mock(returncode=0)
            child.poll.return_value = 0
            with patch.object(runner.fcntl, 'flock'), \
                 patch.object(runner, 'available_memory', side_effect=[v * runner.GIB for v in (70, 80, 80, 80)]) as memory, \
                 patch.object(runner.time, 'sleep'), \
                 patch.object(runner.subprocess, 'Popen', return_value=child) as start:
                self.assertEqual(runner.worker(output), 0)
                self.assertEqual(start.call_args.kwargs['env']['HPU_BUILD_STEP'], 'syn')
                self.assertEqual(memory.call_count, 4)

    def test_service_failure_overrides_stale_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            (output / 'status.json').write_text('{"state": "complete", "exit_code": 0}')
            with patch.dict(runner.os.environ, {'SERVICE_RESULT': 'oom-kill'}):
                runner.finalize(output)
            status = json.loads((output / 'status.json').read_text())
            self.assertEqual(status['state'], 'failed')
            self.assertEqual(status['service_result'], 'oom-kill')

    def test_sustained_memory_pressure_stops_own_child(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            (output / 'build.json').write_text(json.dumps({'repo': str(ROOT), 'vivado_root': '/unused', 'checkpoint': '/unused', 'phase': 'baseline'}))
            child = Mock(pid=12345)
            child.poll.return_value = None
            elapsed = [0]
            def sleep(seconds):
                elapsed[0] += seconds
            def memory():
                return (70 if elapsed[0] < 30 else 7) * runner.GIB
            with patch.object(runner.fcntl, 'flock'), \
                 patch.object(runner, 'available_memory', side_effect=memory), \
                 patch.object(runner.time, 'sleep', side_effect=sleep), \
                 patch.object(runner.time, 'monotonic', side_effect=lambda: elapsed[0]), \
                 patch.object(runner.subprocess, 'Popen', return_value=child), \
                 patch.object(runner.os, 'killpg') as kill:
                self.assertEqual(runner.worker(output), 1)
                kill.assert_called_once_with(12345, runner.signal.SIGTERM)
            self.assertEqual(elapsed[0], 60)
            self.assertIn('below 8 GiB for 30 seconds', json.loads((output / 'status.json').read_text())['error'])

    def test_child_failure_and_missing_artifact(self):
        for rc in (0, 7, -15):
            with self.subTest(returncode=rc), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp)
                (output / 'build.json').write_text(json.dumps({'repo': str(ROOT), 'vivado_root': '/unused', 'checkpoint': '/unused', 'phase': 'baseline'}))
                child = Mock(returncode=rc)
                child.poll.return_value = rc
                with patch.object(runner.fcntl, 'flock'), patch.object(runner, 'available_memory', return_value=70 * runner.GIB), patch.object(runner.time, 'sleep'), patch.object(runner.subprocess, 'Popen', return_value=child):
                    self.assertEqual(runner.worker(output), 1)
                self.assertEqual(json.loads((output / 'status.json').read_text())['state'], 'failed')


if __name__ == '__main__':
    unittest.main()
