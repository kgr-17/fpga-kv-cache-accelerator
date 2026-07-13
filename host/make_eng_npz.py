"""Package the tb_engine test case as an .npz so the identical slice can be run
on hardware (kv_host.py check --npz eng_case.npz --threshold 100) and its
cycles_process compared against the simulated count printed by tb_engine."""
import numpy as np

from make_vectors import engine_slice

entries, imps, vec_len, threshold = engine_slice()
np.savez("eng_case.npz",
         values=np.array([list(e) for e in entries], dtype=np.uint8),
         imps=np.array(imps, dtype=np.uint8),
         scale=np.float64(1.0),
         meta=f"tb_engine case: {len(entries)} entries x {vec_len}, threshold {threshold}")
print(f"wrote eng_case.npz ({len(entries)} x {vec_len}, threshold {threshold})")
