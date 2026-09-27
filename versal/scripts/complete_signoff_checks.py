#!/usr/bin/env python3
"""Extract the remaining signoff metrics; reject unknown report formats."""
import json
from pathlib import Path
import re
import sys


def count(text, label):
    match = re.search(label + r'[ .:|]*([0-9,]+)[ \t]*(?::|\|)?[ \t]*$', text, re.I | re.M)
    if not match:
        raise ValueError(f'Missing report count: {label}')
    return int(match[1].replace(',', ''))


def severity_count(text, title):
    if title.lower() not in text.lower():
        raise ValueError(f'Missing report title: {title}')
    cdc_rows = re.findall(r'^CDC-\d+\s+(Critical|Warning|Info)\s+(\d+)\s+', text, re.M)
    if cdc_rows:
        return sum(int(value) for severity, value in cdc_rows if severity == 'Critical')
    # Only summary-table rows, not free-text recommendations in descriptions.
    rows = [line.split('|')[1:-1] for line in text.splitlines() if line.strip().startswith('|')]
    summaries = [row for row in rows if any(re.fullmatch(r'\s*(?:Warning|Info|Informational|Error|Critical(?: Warning)?)\s*', cell, re.I) for cell in row)]
    if not summaries:
        if re.search(r'(?:No .*?(?:violations|issues|crossings)|Checks found:\s*0)', text, re.I):
            return 0
        raise ValueError(f'Missing severity summary: {title}')
    total = 0
    for row in summaries:
        if any(re.fullmatch(r'\s*(?:Error|Critical(?: Warning)?)\s*', cell, re.I) for cell in row):
            counts = [int(cell.strip()) for cell in row if cell.strip().isdigit()]
            if not counts:
                raise ValueError(f'Missing violation count: {row}')
            total += counts[-1]
    return total


def complete(directory):
    checks = json.loads((directory / 'checks.json').read_text())
    route = (directory / 'route.rpt').read_text()
    routable = count(route, 'routable nets')
    routed = count(route, 'fully routed nets')
    if routable <= 0 or routed > routable:
        raise ValueError('Invalid routing totals')
    checks['unrouted_nets'] = routable - routed
    checks['routing_errors'] = count(route, 'nets with routing errors')
    checks['drc_errors'] = severity_count((directory / 'drc.rpt').read_text(), 'Report DRC')
    checks['methodology_errors'] = severity_count((directory / 'methodology.rpt').read_text(), 'Report Methodology')
    checks['cdc_critical'] = severity_count((directory / 'cdc.rpt').read_text(), 'CDC')
    skew = (directory / 'bus_skew.rpt').read_text()
    slacks = re.findall(r'Slack\s*\((MET|VIOLATED)\)\s*:\s*(-?\d+(?:\.\d+)?)', skew, re.I)
    if slacks:
        checks['bus_skew_violations'] = sum(state.upper() != 'MET' or float(value) < 0 for state, value in slacks)
    elif re.search(r'no bus skew (?:constraints|paths)', skew, re.I):
        checks['bus_skew_violations'] = 0
    else:
        raise ValueError('Missing bus-skew results')
    (directory / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')


if __name__ == '__main__':
    try:
        complete(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        sys.exit(f'SIGNOFF EXTRACTION FAILED: {error}')
