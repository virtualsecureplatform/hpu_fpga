#!/usr/bin/env python3
"""Read-only audit of an AMR HPU release against its sources and TFHE-rs config.

This checks artifact consistency, not FPGA arithmetic or physical memory contents.
It reads archived sources rather than assuming the current checkout was synthesized.
Python 3.11+ is required. The JSON report is printed to stdout.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile
import tomllib
import xml.etree.ElementTree as ET
import zipfile


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--image-dir", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--tfhe-rs", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    tfhe = args.tfhe_rs.resolve()
    failures = []
    report = {"scope": "artifact consistency; no board writes or arithmetic validation"}

    def check(condition, message):
        if not condition:
            failures.append(message)

    manifest = json.loads((args.release / "release_manifest.json").read_text())
    report["expected_uuid"] = manifest["expected_uuid"]
    report["release_hashes"] = {}
    for name, expected in manifest["sha256"].items():
        actual = sha256(args.release / name)
        report["release_hashes"][name] = actual == expected
        check(actual == expected, f"Release hash mismatch: {name}")

    backend = tfhe / "backends/tfhe-hpu-backend"
    config = tomllib.loads((backend / "config_store/v80/hpu_config.toml").read_text())
    check(config["fpga"]["ffi"]["V80Amr"]["expected_uuid"] == manifest["expected_uuid"],
          "Host/release UUID mismatch")
    ffi = (backend / "src/ffi/mod.rs").read_text()
    base = int(re.search(r"MEM_BASE_ADDR: u64 = (0x[\da-fA-F_]+)", ffi)[1].replace("_", ""), 16)
    bank_size = int(re.search(r"MEM_BANK_SIZE_MB: usize = (\d+)", ffi)[1]) * 1024**2
    with zipfile.ZipFile(args.release / "hpu_plug.xsa") as archive:
        hwh = ET.fromstring(archive.read("hpu_plug.hwh"))
    ranges = [node.attrib for node in hwh.findall(".//MEMRANGE")
              if node.get("ADDRESSBLOCK", "").startswith("HBM")]
    noc = next(node for node in hwh.findall(".//MODULE")
               if node.get("INSTANCE") == "noc_wrapper_axi_noc_cips")
    interfaces = {
        node.get("NAME"): {p.get("NAME"): p.get("VALUE", "")
                           for p in node.findall("./PARAMETER")}
        for node in noc.findall("./BUSINTERFACES/BUSINTERFACE")
    }
    mappings = []
    groups = [("bsk_pc", "BSK_AXI"), ("ksk_pc", "KSK_AXI"),
              ("ct_pc", "CT_AXI"), ("lut_pc", "GLWE_AXI"), ("trace_pc", "TRC_AXI")]
    for key, prefix in groups:
        banks = config["board"][key]
        banks = banks if isinstance(banks, list) else [banks]
        for index, bank in enumerate(banks):
            pc = bank["Hbm"]["pc"]
            bus = f"{prefix}_{index}"
            matches = [r for r in ranges if r["MASTERBUSINTERFACE"] == bus]
            check(len(matches) == 1, f"Expected one XSA memory range for {bus}")
            if len(matches) != 1:
                continue
            item = matches[0]
            lo, hi = int(item["BASEVALUE"], 16), int(item["HIGHVALUE"], 16)
            block = f"HBM{pc // 4}_PC{(pc // 2) % 2}"
            expected_port = f"HBM{pc // 4}_PORT{pc % 4}"
            params = interfaces[item["SLAVEBUSINTERFACE"]]
            check((lo, hi) == (base + pc * bank_size, base + (pc + 1) * bank_size - 1),
                  f"Host/XSA range mismatch for {bus}")
            check(item["ADDRESSBLOCK"] == block, f"Physical HBM block mismatch for {bus}")
            check(expected_port in params.get("CONNECTIONS", "").split(),
                  f"Physical HBM port mismatch for {bus}")
            check(not params.get("REMAPS"), f"Unexpected accelerator remap for {bus}")
            expected_width = "128" if prefix == "TRC_AXI" else "256"
            check(params.get("DATA_WIDTH") == expected_width, f"Unexpected AXI width for {bus}")
            for host in ("CPM_PCIE_NOC_0", "CPM_PCIE_NOC_1"):
                host_ranges = [r for r in ranges if r["MASTERBUSINTERFACE"] == host
                               and int(r["BASEVALUE"], 16) <= lo <= hi <= int(r["HIGHVALUE"], 16)]
                check(len(host_ranges) == 1 and host_ranges[0]["ADDRESSBLOCK"] == block,
                      f"Host/accelerator physical HBM mismatch: {host}, {bus}")
            mappings.append({"bus": bus, "host_bank": pc, "base": hex(lo),
                             "high": hex(hi), "physical_block": block,
                             "physical_port": expected_port})
    check(len(mappings) == 36, "Expected 16 BSK, 16 KSK, 2 CT, 1 LUT and 1 trace ports")
    report["hbm_mappings"] = mappings

    # The synthesis project records which variant of each package was selected.
    project = ET.parse(args.project)
    selected = []
    for node in project.findall(".//File"):
        path = Path(node.get("Path", "").replace("$PPRDIR", str(args.project.resolve().parent)))
        try:
            relative = path.resolve().relative_to(repo).as_posix()
        except ValueError:
            continue
        if relative.startswith("hw/") and path.suffix in (".sv", ".v"):
            selected.append(relative)
    selected = sorted(set(selected))
    check(bool(selected), "No hardware sources found in synthesis project")
    hashes = json.loads((args.image_dir / "source_hashes.json").read_text())
    wanted = set(selected) | {"sw/ntt/ntt_gf64.sage"}
    archived = {}
    with tarfile.open(args.image_dir / "source_snapshot.tar.gz", "r:gz") as snapshot:
        for member in snapshot:
            if member.name in wanted and member.isfile():
                archived[member.name] = snapshot.extractfile(member).read()
    changed = []
    for name in selected:
        check(name in archived and name in hashes, f"Missing archived synthesis source: {name}")
        if name not in archived or name not in hashes:
            continue
        check(hashlib.sha256(archived[name]).hexdigest() == hashes[name],
              f"Archived source hash mismatch: {name}")
        if not (repo / name).is_file() or sha256(repo / name) != hashes[name]:
            changed.append(name)
    report["synthesis_sources"] = {"count": len(selected), "current_checkout_differences": changed}

    def source(suffix):
        candidates = [name for name in selected if name.endswith(suffix)]
        if len(candidates) != 1:
            raise ValueError(f"Expected one selected source ending in {suffix}: {candidates}")
        return archived[candidates[0]].decode()

    def integer(text, name):
        text = re.sub(r"//[^\n]*", "", text)
        return int(re.search(r"\b" + name + r"\s*=\s*(\d+)\s*;", text)[1])

    tfhe_package = source("/param_tfhe_definition_pkg.sv")
    names = {"N": 2048, "GLWE_K": 1, "LWE_K": 879, "MOD_Q_W": 64,
             "PBS_B_W": 23, "PBS_L": 1, "KS_B_W": 2, "KS_L": 8,
             "MOD_KSK_W": 21, "PAYLOAD_BIT": 4, "PADDING_BIT": 1}
    params = {name: integer(tfhe_package, name) for name in names}
    for name, expected in names.items():
        check(params[name] == expected, f"Unexpected build parameter {name}: {params[name]}")
    check(bool(re.search(r"USE_MEAN_COMP\s*=\s*1'b1", tfhe_package)), "Mean compensation disabled")
    params["USE_MEAN_COMP"] = True
    for suffix, keys in [("/ntt_core_common_psi_definition_pkg.sv", ["PSI"]),
                         ("/pep_ks_common_definition_pkg.sv", ["LBX", "LBY", "LBZ"])]:
        for name in keys:
            params[name] = integer(source(suffix), name)
    check([params[k] for k in ("PSI", "LBX", "LBY", "LBZ")] == [64, 3, 64, 3],
          "Unexpected NTT/KS parallelism")
    cut_text = source("/ntt_core_common_cut_definition_pkg.sv")
    cuts = list(reversed([int(x) for x in re.findall(r"32'd(\d+)", cut_text)]))
    check(cuts == [5, 6], f"Unexpected NTT cuts: {cuts}")
    params["NTT_RDX_CUT_S"] = cuts
    report["build_parameters"] = params

    # Validate every generated phi against modular exponentiation and the CPU root.
    prime = 2**64 - 2**32 + 1
    generator_text = archived["sw/ntt/ntt_gf64.sage"].decode()
    root32 = int(re.search(r"OMG_2_32\s*=\s*ZQ\((\d+)\)", generator_text)[1])
    cpu_ntt = (tfhe / "tfhe-ntt/src/prime64.rs").read_text()
    cpu_root = int(re.search(r"2048\s*=>\s*(\d+)_u64", cpu_ntt)[1])
    rtl_root = pow(root32, 2**32 // (2 * params["N"]), prime)
    check(cpu_root == rtl_root, "CPU/RTL NTT root mismatch")
    table_text = source("/ntt_core_gf64_phi_phi_pkg.sv")
    table_reports = []
    for name, direction, divide, n_text, body in re.findall(
            r"(NTT_GF64_(FWD|BWD)(_WDIV)?_N(\d+)_PHI_L)\s*=\s*\{(.*?)\};",
            table_text, re.S):
        n = int(n_text)
        values = list(reversed([int(v, 16) for v in re.findall(r"64'h([0-9a-fA-F]+)", body)]))
        root = pow(root32, 2**32 // (2 * n), prime)
        if direction == "BWD":
            root = pow(root, -1, prime)
        expected = pow(n, -1, prime) if divide else 1
        mismatches = 0
        for value in values:
            mismatches += value != expected
            expected = expected * root % prime
        check(len(values) == 2 * n and mismatches == 0, f"Incorrect phi table: {name}")
        table_reports.append({"name": name, "entries": len(values), "mismatches": mismatches})
    check(len(table_reports) == 30, "Expected 30 generated phi tables")
    report["ntt_tables"] = {"root_4096": rtl_root, "cpu_root_4096": cpu_root,
                             "tables": table_reports}
    report["limitations"] = [
        "Does not inspect FPGA key-cache contents or capture intermediate ciphertexts.",
        "Source/hash and XSA checks do not prove the implemented netlist is mathematically correct.",
        "Build parameters are checked for this 2048/GF64/PSI64 variant; compare live registers separately.",
    ]
    report["failures"] = failures
    report["passed"] = not failures
    print(json.dumps(report, indent=2))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
