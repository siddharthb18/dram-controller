#!/usr/bin/env python3
# Reads the simulation logs from a regression and prints one table.
# Each log ends with RESULT / COVERAGE / TEST lines printed by tb_top.sv.
#
#   python3 scripts/parse_logs.py logs/seed_*.log
#
# Also writes results/summary.csv. Exits with 1 if any run failed.

import csv
import re
import sys
from pathlib import Path

COLS = ["log", "status", "txns", "hits", "misses", "empties", "refreshes",
        "collisions", "mismatches", "timing_errors", "cov_req", "cov_ref"]


def parse(path):
    run = {"log": path.name, "status": "NO RESULT"}
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("RESULT") or line.startswith("COVERAGE"):
            prefix = "cov_" if line.startswith("COVERAGE") else ""
            for key, val in re.findall(r"(\w+)=([\d.]+)", line):
                run[prefix + key] = float(val) if "." in val else int(val)
        elif "TEST PASSED" in line:
            run["status"] = "PASS"
        elif "TEST FAILED" in line:
            run["status"] = "FAIL"
    return run


def seed_number(path):
    m = re.search(r"(\d+)", path.name)
    return int(m.group(1)) if m else 0


runs = [parse(p) for p in sorted(map(Path, sys.argv[1:]), key=seed_number)]
if not runs:
    sys.exit("no logs given")

print("  ".join(f"{c:>13}" for c in COLS))
for r in runs:
    print("  ".join(f"{str(r.get(c, '-')):>13}" for c in COLS))

passed = sum(r["status"] == "PASS" for r in runs)
txns = sum(r.get("txns", 0) for r in runs)
hits = sum(r.get("hits", 0) for r in runs)
print(f"\n{passed}/{len(runs)} passed, {txns} transactions, "
      f"row hit rate {100 * hits / max(txns, 1):.1f}%")

Path("results").mkdir(exist_ok=True)
with open("results/summary.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=COLS, extrasaction="ignore", lineterminator="\n")
    w.writeheader()
    w.writerows(runs)

sys.exit(0 if passed == len(runs) else 1)
