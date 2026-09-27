#!/usr/bin/env python3
"""Validate repair inputs and select non-regressing legal timing candidates."""
import json
import math
from pathlib import Path
import sys
from complete_signoff_checks import count
from check_timing_signoff import timing_metrics


def validate_input(text, net, endpoint):
    if count(text, 'routable nets') - count(text, 'fully routed nets') != 1 or count(text, 'nets with routing errors') != 1:
        raise ValueError('Expected exactly one incomplete net and one routing error')
    if f'  {net}\n' not in text or f'      {endpoint}\n' not in text:
        raise ValueError('Expected defective net/endpoint absent from routing report')


def extract(stage):
    prefix = str(stage)
    data = timing_metrics(Path(prefix + '_timing.rpt').read_text())
    numeric = json.loads(Path(prefix + '_numeric.json').read_text())
    for key in ('wns', 'whs'):
        value = numeric[key]
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError('Missing or nonfinite numeric slack')
        data[key] = value
    route = Path(prefix + '_route.rpt').read_text()
    total = count(route, 'routable nets')
    routed = count(route, 'fully routed nets')
    data['legal'] = numeric['legal'] == 1 and total > 0 and total == routed and count(route, 'nets with routing errors') == 0
    Path(prefix + '_metrics.json').write_text(json.dumps(data, indent=2) + '\n')
    return data


def acceptable(best, candidate):
    return (candidate['legal'] and candidate['whs'] >= 0 and candidate['hold_failing'] == 0
            and candidate['wpws'] >= 0 and candidate['pulse_failing'] == 0
            and candidate['setup_total'] > 0 and candidate['hold_total'] > 0 and candidate['pulse_total'] > 0
            and candidate['wns'] >= best['wns'] and candidate['tns'] >= best['tns'])


def eligible(data):
    required = ('wns', 'tns', 'whs', 'ths', 'wpws', 'tpws',
                'setup_failing', 'hold_failing', 'pulse_failing',
                'setup_total', 'hold_total', 'pulse_total')
    return (all(isinstance(data.get(k), (int, float)) and math.isfinite(data[k]) for k in required)
            and data.get('legal') is True and data['whs'] >= 0 and data['ths'] >= 0
            and data['hold_failing'] == 0 and data['wpws'] >= 0 and data['tpws'] >= 0
            and data['pulse_failing'] == 0
            and all(data[k] > 0 for k in ('setup_total', 'hold_total', 'pulse_total')))


def timing_pass(data):
    return eligible(data) and data['wns'] >= 0 and data['tns'] >= 0 and data['setup_failing'] == 0


def select(stages):
    candidates = [(name, read(name)) for name in stages]
    candidates = [(name, data) for name, data in candidates if eligible(data)]
    if not candidates:
        raise ValueError('No legally routed candidate passes hold and pulse-width checks')
    # max keeps the first candidate on equal WNS/TNS.
    return max(candidates, key=lambda item: (item[1]['wns'], item[1]['tns']))[0]


def read(stage):
    return json.loads(Path(str(stage) + '_metrics.json').read_text())


if __name__ == '__main__':
    try:
        mode, *args = sys.argv[1:]
        if mode == 'input':
            validate_input(Path(args[0]).read_text(), args[1], args[2])
        elif mode == 'extract':
            extract(args[0])
        elif mode == 'legal':
            print('yes' if read(args[0]).get('legal') is True else 'no')
        elif mode == 'eligible':
            print('yes' if eligible(read(args[0])) else 'no')
        elif mode == 'timing_pass':
            print('yes' if timing_pass(read(args[0])) else 'no')
        elif mode == 'select':
            print(select(args))
        elif mode == 'compare':
            print('accept' if acceptable(read(args[0]), read(args[1])) else 'reject')
        elif mode == 'setup_pass':
            data = read(args[0])
            print('yes' if data['wns'] >= 0 and data['setup_failing'] == 0 else 'no')
        else:
            raise ValueError(f'Unknown mode: {mode}')
    except (ValueError, OSError, KeyError) as error:
        sys.exit(f'REPAIR VALIDATION FAILED: {error}')
