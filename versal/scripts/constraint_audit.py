"""Exact evidence-backed audit of grounded or vendor-case-disabled GT controls."""
import hashlib
import json
from pathlib import Path
import re

PREFIX = 'hpu_plug_wrapper/hpu_plug_i/shell_wrapper/cips/inst/cpm_0/inst'
CONTROLS = ('PHYESMADAPTSAVE', 'RXDLYALIGNREQ', 'RXMLDCHAINDONE',
            'RXMLDCHAINREQ', 'RXPHALIGNREQ', 'RXPHSETINITREQ', 'RXPHSHIFT180')
EXPECTED = {f'{PREFIX}/gt_quad_inst{q}/inst/quad_inst/CH{ch}_{control}'
            for q in (2, 3) for ch in range(4) for control in CONTROLS}

DRIVER_SUFFIXES = dict(zip(CONTROLS, (
    'PHYESMADAPTATIONSAVE', 'RXDELAYALIGNREQ', 'RXMLDCHAINDONE',
    'RXMLDCHAINREQ', 'RXPHASEALIGNREQ', 'RXPHASESETINITREQ', 'RXPHASESHIFT180REQ')))
DRIVER_SUFFIXES['RXUSRCLK'] = 'RXUSRCLK'
EXPECTED_DRIVERS = {
    f'{PREFIX}/gt_quad_inst{q}/inst/quad_inst/CH{ch}_{control}':
    f'{PREFIX}/CPM_INST/IFFCQ{q}{ch}{suffix}FS'
    for q in (2, 3) for ch in range(4) for control, suffix in DRIVER_SUFFIXES.items()}


def constraints_digest(text):
    # Vivado generates waiver creation timestamps afresh for each build. They
    # do not affect the waiver's scope or behavior. Preserve all other Tcl
    # except placement-only LOCs for HPU replicas, including CPM overrides.
    commands = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('create_waiver '):
            line = re.sub(r' -timestamp "[^"]+"$', ' -timestamp "<generated>"', line)
        # Post-route physical optimization may create placement LOCs for HPU
        # replicas. Their locations are checked by route/timing signoff; they
        # cannot alter the CPM's scoped case analysis. Keep every non-HPU LOC.
        if re.fullmatch(r'set_property LOC SLICE_X\d+Y\d+ '
                        r'\[get_cells \{?hpu_3parts/[^\s}]+\}?\]', line):
            continue
        commands.append(line)
    commands = '\n'.join(commands)
    return hashlib.sha256(commands.encode()).hexdigest()


UUID_CELL = ('hpu_plug_wrapper/hpu_plug_i/shell_wrapper/base_logic/uuid_rom/U0/'
             'xpm_memory_spram_inst/xpm_memory_base_inst/'
             'gen_wr_a.gen_word_narrow.mem_reg_0_3_')


def image_constraints(text, manifest):
    """Remove only a complete, manifest-matching image metadata update."""
    match = re.fullmatch(r'logic_uuid ([0-9a-fA-F]{32}) interface_uuid ([0-9a-fA-F]{32})\s*', manifest)
    if not match:
        raise ValueError('Invalid image UUID manifest')
    uuid = match[1].lower()
    init_pattern = re.compile(r"set_property INIT 32'h0000000([0-9A-Fa-f]) \[get_cells "
                              + re.escape(UUID_CELL) + r'(\d+)_(\d+)\]')
    inits, kept = {}, []
    create_count = timestamp_count = 0
    for line in text.splitlines():
        command = line.strip()
        init = init_pattern.fullmatch(command)
        if init:
            index = int(init[2])
            if init[2] != str(index) or init[3] != str(index) or index in inits:
                raise ValueError('Duplicate or malformed UUID ROM cell')
            inits[index] = int(init[1], 16)
        elif command == 'create_property INIT cell -type string':
            create_count += 1
        elif command == 'set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]':
            timestamp_count += 1
        else:
            kept.append(line)
    if set(inits) != set(range(32)) or create_count != 1 or timestamp_count != 1:
        raise ValueError('Incomplete or duplicate image metadata update')
    # AMD update_uuid_rom packs bit i of four 32-bit UUID words into INIT[i].
    words = [int(uuid[i:i+8], 16) for i in range(0, 32, 8)][::-1]
    expected = {i: sum(((word >> i) & 1) << j for j, word in enumerate(words))
                for i in range(32)}
    if inits != expected:
        raise ValueError('UUID ROM contents do not match image manifest')
    return '\n'.join(kept), uuid


def vendor_evidence(directory, policy):
    if 'vendor_cpm' not in policy:
        return False
    constraints = (directory / 'gt_checkpoint_constraints.xdc').read_text()
    if constraints_digest(constraints) != policy['vendor_cpm']['constraints_sha256']:
        manifest = directory / 'pfm_uuid_manifest.dict'
        if not manifest.is_file():
            raise ValueError('Checkpoint constraints changed; vendor CPM audit must be repeated')
        constraints, _ = image_constraints(constraints, manifest.read_text())
        if constraints_digest(constraints) != policy['vendor_cpm']['constraints_sha256']:
            raise ValueError('Checkpoint constraints changed beyond validated image metadata')
    # Pin the entire reviewed export, including scope and any later overrides.
    rows = {}
    for line in (directory / 'gt_cpm_drivers.tsv').read_text().splitlines():
        fields = line.split('\t')
        if len(fields) != 4 or fields[0] in rows:
            raise ValueError('Malformed or duplicate CPM driver evidence')
        rows[fields[0]] = fields[1:]
    if set(rows) != set(EXPECTED_DRIVERS):
        raise ValueError('Missing or additional CPM driver evidence')
    for pin, driver in EXPECTED_DRIVERS.items():
        if rows[pin] != [driver, 'CPM5', '0']:
            raise ValueError(f'CPM driver or clock evidence changed: {pin}')
    return True


def config_identity(path):
    ip = json.loads(path.read_text())['ip_inst']
    parameters = ip['parameters']['component_parameters']
    return {'vlnv': ip['component_reference'], 'revision': ip['ip_revision'],
            'parameters_sha256': hashlib.sha256(
                json.dumps(parameters, sort_keys=True).encode()).hexdigest()}


def audit(directory):
    text = (directory / 'check_timing.rpt').read_text()
    categories = dict(re.findall(r'checking\s+(\w+)\s*\((\d+)\)', text))
    raw = int(categories['unconstrained_internal_endpoints'])
    result = {'raw': raw, 'justified': 0, 'unresolved': raw, 'endpoints': []}
    if raw == 0:
        return result
    # Parse only the detailed constant-clock subsection, not its summary count.
    section = re.search(r'There are (\d+) pins that are not constrained for maximum delay due to constant clock\.[^\n]*\n(.*?)(?=\n\d+\. checking|\Z)', text, re.S)
    if section is None:
        raise ValueError('Missing detailed constant-clock endpoint list')
    endpoints = [line.strip() for line in section[2].splitlines() if line.strip()]
    if len(endpoints) != int(section[1]) or len(set(endpoints)) != len(endpoints):
        raise ValueError('Invalid constant-clock endpoint enumeration')
    if set(endpoints) != EXPECTED or raw != len(EXPECTED):
        raise ValueError('Unconstrained endpoints differ from the audited V80 set')
    policy = json.loads((directory / 'inactive_gt_policy.json').read_text())
    metadata = json.loads((directory / 'gt_evidence_metadata.json').read_text())
    identity = config_identity(directory / 'cips.xci')
    if metadata['tool_version'] != policy['tool_version'] or identity != policy['cips']:
        raise ValueError('Tool/IP configuration changed; inactive-GT audit must be repeated')
    vendor_proven = vendor_evidence(directory, policy)
    rows = {}
    for line in (directory / 'gt_endpoint_evidence.tsv').read_text().splitlines():
        fields = line.split('\t')
        if len(fields) != 6 or fields[0] in rows:
            raise ValueError('Malformed or duplicate netlist evidence')
        rows[fields[0]] = fields
    if set(rows) != EXPECTED:
        raise ValueError('Missing or additional netlist endpoint evidence')
    for pin in sorted(EXPECTED):
        _, primitive, data_net, data_gnd, clock_net, clock_gnd = rows[pin]
        # Merely being inside vendor IP is not evidence of inactivity.
        proven = (primitive == 'GTYP_QUAD' and bool(data_net) and bool(clock_net)
                  and data_gnd == '1' and clock_gnd == '1')
        vendor = (vendor_proven and primitive == 'GTYP_QUAD'
                  and bool(data_net) and bool(clock_net) and data_gnd == '0' and clock_gnd == '0')
        result['endpoints'].append({'pin': pin, 'inactive': proven,
                                    'classification': ('grounded' if proven else
                                        'vendor_case_disabled_cpm5_gt_controls' if vendor else 'unresolved'),
                                    'driver': EXPECTED_DRIVERS[pin] if vendor else None,
                                    'data_net': data_net, 'clock_net': clock_net})
        result['justified'] += int(proven or vendor)
    result['unresolved'] = raw - result['justified']
    result['tool_version'] = metadata['tool_version']
    result['cips'] = identity
    return result
