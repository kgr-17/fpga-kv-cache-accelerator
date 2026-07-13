"""Batch simulation runner: compile all RTL + TBs with xvlog, elaborate and run
each testbench with xelab/xsim, and check for its PASS line.

Usage: python scripts/run_sims.py [tb_name ...]   (default: all testbenches)
"""
import glob
import os
import subprocess
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VIVADO_BIN = r"C:\AMDDesignTools\2025.2\Vivado\bin"
# Run 4 levels below the repo root so the TBs' default VEC_DIR
# ("../../../../sim/vectors", matching Vivado GUI sim depth) resolves without
# parameter overrides (the xelab.bat wrapper mangles '=' in -generic_top args).
WORK = os.path.join(REPO, "sim", "work", "behav", "xsim")

ALL_TBS = ["tb_uart_loopback", "tb_delta_enc", "tb_rle_enc", "tb_vec_buffer",
           "tb_units", "tb_engine", "tb_restore", "tb_kv_top_full"]


def run(cmd, cwd, log_name):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=1800)
    log = os.path.join(WORK, log_name)
    with open(log, "w", encoding="utf-8", errors="replace") as f:
        f.write("CMD: " + " ".join(cmd) + "\n\n" + r.stdout + "\n" + r.stderr)
    return r


def main():
    tbs = sys.argv[1:] or ALL_TBS
    os.makedirs(WORK, exist_ok=True)
    sources = sorted(glob.glob(os.path.join(REPO, "rtl", "*.v"))) + \
              sorted(glob.glob(os.path.join(REPO, "sim", "tb_*.v")))
    print(f"compiling {len(sources)} files ...")
    r = run([os.path.join(VIVADO_BIN, "xvlog.bat")] + sources, WORK, "xvlog.log")
    if r.returncode != 0 or "ERROR" in r.stdout:
        print(r.stdout[-4000:])
        print("FAIL: xvlog compile errors (see sim/work/xvlog.log)")
        sys.exit(1)
    print("compile OK")

    results = {}
    for tb in tbs:
        snap = f"{tb}_snap"
        r = run([os.path.join(VIVADO_BIN, "xelab.bat"), tb, "-s", snap,
                 "-timescale", "1ns/1ps"],
                WORK, f"xelab_{tb}.log")
        if r.returncode != 0 or "ERROR" in r.stdout:
            results[tb] = "ELAB-FAIL"
            print(f"{tb}: ELAB-FAIL (see sim/work/xelab_{tb}.log)")
            continue
        r = run([os.path.join(VIVADO_BIN, "xsim.bat"), snap, "-R"],
                WORK, f"xsim_{tb}.log")
        out = r.stdout
        if f"PASS: {tb}" in out and "FAIL" not in out:
            results[tb] = "PASS"
        else:
            results[tb] = "FAIL"
        print(f"{tb}: {results[tb]}")

    print("\n==== summary ====")
    for tb, res in results.items():
        print(f"  {tb:20s} {res}")
    sys.exit(0 if all(v == "PASS" for v in results.values()) else 1)


if __name__ == "__main__":
    main()
