#!/usr/bin/env python3
"""Fail closed on incomplete or failing Vivado signoff reports."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from complete_signoff_checks import complete
from constraint_audit import audit


def timing_metrics(text):
    header = re.search(r'WNS\(ns\).*TNS\(ns\).*WHS\(ns\).*THS\(ns\).*WPWS\(ns\).*TPWS\(ns\)', text)
    if not header:
        raise ValueError('Missing design timing summary header')
    for line in text[header.end():].splitlines()[:8]:
        fields = line.split()
        if len(fields) == 12:
            try:
                values = list(map(float, fields))
            except ValueError:
                continue
            if not all(math.isfinite(v) for v in values):
                raise ValueError('Non-finite timing values')
            return dict(zip(('wns', 'tns', 'setup_failing', 'setup_total',
                             'whs', 'ths', 'hold_failing', 'hold_total',
                             'wpws', 'tpws', 'pulse_failing', 'pulse_total'), values))
    raise ValueError('Missing or malformed design timing summary values')


def validate_metrics(metrics):
    failures = []
    for key in ('wns', 'tns', 'whs', 'ths', 'wpws', 'tpws'):
        if metrics[key] < 0:
            failures.append(f'{key} is negative: {metrics[key]}')
    for key in ('setup_failing', 'hold_failing', 'pulse_failing'):
        if metrics[key] != 0:
            failures.append(f'{key} is nonzero: {metrics[key]}')
    if metrics['setup_total'] <= 0 or metrics['hold_total'] <= 0 or metrics['pulse_total'] <= 0:
        failures.append('Empty timing analysis')
    if failures:
        raise ValueError('; '.join(failures))


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def record_checkpoint(directory, checkpoint):
    checkpoint = checkpoint.resolve(strict=True)
    (directory / 'checkpoint.json').write_text(json.dumps(
        {'path': str(checkpoint), 'sha256': digest(checkpoint)}, indent=2) + '\n')


def check(directory, checkpoint=None):
    required = ['timing.rpt', 'route.rpt', 'bus_skew.rpt', 'drc.rpt',
                'methodology.rpt', 'cdc.rpt', 'clocks.rpt', 'exceptions.rpt', 'checks.json',
                'check_timing.rpt', 'checkpoint.json', 'clock_validation.json',
                'clock_properties.rpt', 'clock_drc.rpt']
    reports = {}
    for name in required:
        path = directory / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'Missing or empty report: {name}')
        reports[name] = path.read_text()
    # Re-extract on every invocation so stale checks cannot hide changed reports.
    failures = []
    try:
        complete(directory)
    except (ValueError, OSError, KeyError) as error:
        failures.append(str(error))
    metrics = timing_metrics(reports['timing.rpt'])
    try:
        validate_metrics(metrics)
    except ValueError as error:
        failures.append(str(error))
    checks = json.loads((directory / 'checks.json').read_text())
    for key in ('setup_paths', 'hold_paths'):
        if checks.get(key) != 0:
            failures.append(f'{key} is missing or failing')
    for key in ('processing_mhz', 'free_running_mhz'):
        value = checks.get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(value) or abs(value - 350) > 0.05:
            failures.append(f'{key} is not 350 MHz')
    for key in ('routing_errors', 'unrouted_nets', 'drc_errors', 'methodology_errors', 'cdc_critical', 'bus_skew_violations'):
        if checks.get(key) != 0:
            failures.append(f'{key} is missing or failing')
    # The built-in timing checks enumerate missing clocks/delays and endpoints.
    for report in ('timing.rpt', 'check_timing.rpt'):
        categories = dict(re.findall(r'checking\s+(\w+)\s*\((\d+)\)', reports[report], re.I))
        for name in ('no_clock', 'multiple_clock', 'no_input_delay', 'no_output_delay'):
            if name not in categories or int(categories[name]) != 0:
                failures.append(f'{report}: timing check {name} is missing or nonzero')
    try:
        (directory / 'constraint_audit.json').unlink(missing_ok=True)
        constraint_audit = audit(directory)
        (directory / 'constraint_audit.json').write_text(json.dumps(constraint_audit, indent=2) + '\n')
        required.append('constraint_audit.json')
        summary = re.findall(r'checking\s+unconstrained_internal_endpoints\s*\((\d+)\)', reports['timing.rpt'])
        if not summary or any(int(n) != constraint_audit['raw'] for n in summary):
            raise ValueError('Timing reports disagree on unconstrained endpoint counts')
        if constraint_audit['raw']:
            required.extend(['cips.xci', 'inactive_gt_policy.json', 'gt_evidence_metadata.json',
                             'gt_endpoint_evidence.tsv', 'gt_quad2_properties.rpt', 'gt_quad3_properties.rpt'])
        if constraint_audit['unresolved']:
            failures.append(f"Unresolved unconstrained endpoints: {constraint_audit['unresolved']}")
        if any(e.get('classification') == 'vendor_case_disabled_cpm5_gt_controls'
               for e in constraint_audit['endpoints']):
            required.extend(['gt_cpm_drivers.tsv', 'gt_checkpoint_constraints.xdc'])
            if (directory / 'pfm_uuid_manifest.dict').is_file():
                required.append('pfm_uuid_manifest.dict')
    except (ValueError, OSError, KeyError) as error:
        failures.append(f'Constraint audit: {error}')
    from complete_signoff_checks import severity_count
    if (json.loads(reports['clock_validation.json']).get('passed') is not True
            or severity_count(reports['clock_drc.rpt'], 'Report DRC') != 0):
        failures.append('Clock topology validation failed')
    identity = json.loads(reports['checkpoint.json'])
    candidate = checkpoint or Path(identity['path'])
    if not candidate.is_file() or digest(candidate) != identity['sha256']:
        failures.append('Checkpoint is missing or changed since signoff')
    if failures:
        raise ValueError('\n'.join(failures))
    hashes = {name: digest(directory / name) for name in required}
    return {'passed': True, 'metrics': metrics, 'constraint_audit': constraint_audit,
            'checkpoint_sha256': identity['sha256'], 'reports_sha256': hashes}


def verify_signed(directory, checkpoint=None):
    previous = json.loads((directory / 'signoff.json').read_text())
    current = check(directory, checkpoint)
    if previous != current:
        raise ValueError('Signoff evidence changed after acceptance')
    return current


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--checkpoint', type=Path)
    parser.add_argument('--record-checkpoint', action='store_true')
    parser.add_argument('--verify-existing', action='store_true')
    args = parser.parse_args()
    marker = args.directory / 'signoff.json'
    if not args.verify_existing:
        marker.unlink(missing_ok=True)
    try:
        if args.record_checkpoint and args.verify_existing:
            raise ValueError('Cannot record a new checkpoint while verifying existing signoff')
        if args.record_checkpoint:
            if args.checkpoint is None:
                raise ValueError('--record-checkpoint requires --checkpoint')
            record_checkpoint(args.directory, args.checkpoint)
        result = (verify_signed if args.verify_existing else check)(args.directory, args.checkpoint)
    except (ValueError, OSError, KeyError) as error:
        print(f'SIGNOFF FAILED: {error}', file=sys.stderr)
        sys.exit(1)
    if not args.verify_existing:
        marker.write_text(json.dumps(result, indent=2) + '\n')
    print('SIGNOFF PASSED')
