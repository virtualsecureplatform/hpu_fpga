"""Fresh-build candidate selection and continuation must preserve signoff gates."""
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from test_close_timing import ROOT, BASE, PASS, HOLD_PASS
from test_timing_flow import runner


class FreshTests(unittest.TestCase):
    def test_placement_resume_rejects_non_opt_checkpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = Mock(output=root / 'new', source_build=root,
                        checkpoint=root / 'routed.dcp', phase='place')
            with self.assertRaisesRegex(ValueError, 'top_hpu_opt.dcp'):
                runner.launch(args)
            self.assertFalse((root / 'new').exists())

    def test_late_source_failure_retracts_release_without_deleting_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'build.json').write_text(json.dumps({'repo': str(ROOT), 'phase': 'image',
                'source_guard': True, 'checkpoint': '/unused', 'vivado_root': '/unused'}))
            (root / 'image.complete').touch()
            (root / 'release').mkdir()
            (root / 'release/test.pdi').write_bytes(b'preserve diagnostic image')
            child = Mock(returncode=0)
            child.poll.return_value = 0
            with patch.object(runner, 'verify_sources', side_effect=[None, RuntimeError('Source drift detected')]), \
                 patch.object(runner, 'available_memory', return_value=80 * runner.GIB), \
                 patch.object(runner.time, 'sleep'), patch.object(runner.fcntl, 'flock'), \
                 patch.object(runner.subprocess, 'Popen', return_value=child):
                self.assertEqual(runner.worker(root), 1)
            self.assertFalse((root / 'release').exists())
            self.assertFalse((root / 'image.complete').exists())
            rejected = list(root.glob('release.rejected.*'))
            self.assertEqual(len(rejected), 1)
            self.assertEqual((rejected[0] / 'test.pdi').read_bytes(), b'preserve diagnostic image')

    def test_fresh_completion_without_signoff_never_launches_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'systemd_unit').write_text('test.service')
            (root / 'status.json').write_text('{"state": "complete"}')
            (root / 'fresh.complete').touch()
            with patch.object(sys, 'argv', ['finish_timing_image.py', str(root), str(root / 'image')]), \
                 patch('subprocess.run', return_value=Mock(returncode=3)) as command:
                with self.assertRaisesRegex(SystemExit, 'Routing signoff did not pass'):
                    runpy.run_path(str(ROOT / 'scripts/finish_timing_image.py'), run_name='__main__')
                self.assertEqual(command.call_count, 1)

    def test_source_and_input_drift_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'rtl.sv'
            source.write_text('original')
            original = runner.sha256(source)
            (root / 'source_hashes.json').write_text(json.dumps({'rtl.sv': original}))
            config = {'repo': str(root), 'source_guard': True,
                      'inputs': {'checkpoint': {'path': str(source), 'sha256': original}}}
            with patch.object(runner, 'source_files', return_value=[('rtl.sv', source)]):
                runner.verify_sources(root, config)
                runner.verify_inputs(root, config)
                source.write_text('changed')
                with self.assertRaisesRegex(RuntimeError, 'Source drift'):
                    runner.verify_sources(root, config)
                with self.assertRaisesRegex(RuntimeError, 'Build input changed'):
                    runner.verify_inputs(root, config)

    def run_candidates(self, initial, explore, hold):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, metrics in [('route_input', initial), ('route_explore', explore), ('route_hold', hold)]:
                (root / f'{name}_metrics.json').write_text(json.dumps(metrics))
            script = r'''
source {HELPER}
proc mark_stage {name} {puts "STAGE $name"}
proc hpu_repair::require_legal {name} {}
proc hpu_repair::snapshot {name} {close [open ${name}.dcp w]}
proc hpu_repair::optimize {name args} {puts "OPT $name $args"}
proc close_design {} {}
proc open_checkpoint {name} {puts "OPEN $name"}
set rc [catch {hpu_repair::postroute} message]
puts "RESULT $rc $message"
'''.replace('HELPER', str(ROOT / 'versal/scripts/repair_route.tcl'))
            result = subprocess.run(['tclsh'], input=script, cwd=root, text=True, capture_output=True)
            self.assertEqual(result.stderr, '')
            return result.stdout

    def test_passing_initial_route_is_preserved(self):
        result = self.run_candidates(PASS, BASE, BASE)
        self.assertIn('selected_route_input', result)
        self.assertNotIn('OPT ', result)

    def test_bad_optimization_restarts_hold_pass_from_legal_input(self):
        result = self.run_candidates(HOLD_PASS, dict(BASE, legal=False), PASS)
        self.assertIn('OPEN route_input.dcp', result)
        self.assertIn('selected_route_hold', result)

    def test_no_eligible_candidate_fails(self):
        result = self.run_candidates(BASE, BASE, dict(PASS, legal=False))
        self.assertIn('RESULT 1', result)
        self.assertNotIn('STAGE selected_', result)
