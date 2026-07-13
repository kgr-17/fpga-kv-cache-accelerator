"""Derive energy/throughput figures-of-merit from the Vivado power report and the
measured hardware run. Prints a report-card block and writes docs/reports/fom.txt.

Power: parsed from docs/reports/power.rpt (vectorless estimate, Low confidence).
Timing: measured on the board (threshold-3 run on distilgpt2 l2h5k K slice).
Engine energy is baud-independent — the PROCESS phase runs at 100 MHz regardless
of the UART divisor, so these numbers hold for both the 921k and 2M bitstreams.
"""
import os
import re

REPORTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "docs", "reports")

# measured on hardware, threshold 3 (see docs/results.md)
F_CLK = 100e6
CYCLES = 26941
ORIG_BYTES = 25728        # all tokens examined (system view)
KEPT_BYTES = 5184         # 81 tokens x 64 B, actually pushed through the pipeline


def parse_power(path):
    txt = open(path).read()
    def grab(label):
        m = re.search(r"\|\s*" + re.escape(label) + r"\s*\|\s*([0-9.]+)", txt)
        return float(m.group(1)) if m else None
    return (grab("Total On-Chip Power (W)"),
            grab("Dynamic (W)"),
            grab("Device Static (W)"))


def main():
    p_total, p_dyn, p_stat = parse_power(os.path.join(REPORTS, "power.rpt"))
    t_proc = CYCLES / F_CLK
    tp_sys = ORIG_BYTES / t_proc
    tp_eng = KEPT_BYTES / t_proc

    def nj_per_byte(power, nbytes):
        return power * t_proc / nbytes * 1e9      # nJ/byte

    lines = []
    def emit(s=""):
        lines.append(s)
        print(s)

    emit("=== KV-cache optimizer — energy / throughput figures of merit ===")
    emit(f"clock                 : {F_CLK/1e6:.0f} MHz")
    emit(f"process time / slice  : {t_proc*1e3:.3f} ms ({CYCLES} cycles)")
    emit("")
    emit(f"power (vectorless, Low confidence):")
    emit(f"  total on-chip       : {p_total*1e3:.0f} mW")
    emit(f"  dynamic             : {p_dyn*1e3:.0f} mW")
    emit(f"  static (chip idle)  : {p_stat*1e3:.0f} mW")
    emit("")
    emit(f"throughput (engine, PROCESS phase):")
    emit(f"  system (orig bytes) : {tp_sys/1e6:.1f} MB/s")
    emit(f"  engine (kept bytes) : {tp_eng/1e6:.1f} MB/s")
    emit("")
    emit(f"energy per byte:")
    emit(f"  per orig byte  (total pwr) : {nj_per_byte(p_total, ORIG_BYTES):.2f} nJ/byte")
    emit(f"  per kept byte  (total pwr) : {nj_per_byte(p_total, KEPT_BYTES):.2f} nJ/byte")
    emit(f"  per orig byte  (dyn only)  : {nj_per_byte(p_dyn, ORIG_BYTES):.2f} nJ/byte")
    emit(f"  per kept byte  (dyn only)  : {nj_per_byte(p_dyn, KEPT_BYTES):.2f} nJ/byte")
    emit("")
    emit(f"throughput per watt (system):")
    emit(f"  total power         : {tp_sys/p_total/1e9:.2f} GB/s/W  "
         f"({tp_sys*8/p_total/1e9:.1f} Gbps/W)")
    emit(f"  dynamic power        : {tp_sys/p_dyn/1e9:.2f} GB/s/W  "
         f"({tp_sys*8/p_dyn/1e9:.1f} Gbps/W)")
    emit("")
    emit("note: static power is the fixed cost of a mostly-empty 20k-LUT chip;")
    emit("the dynamic figures better reflect the engine's own cost.")

    with open(os.path.join(REPORTS, "fom.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"\nwrote {os.path.join(REPORTS, 'fom.txt')}")


if __name__ == "__main__":
    main()
