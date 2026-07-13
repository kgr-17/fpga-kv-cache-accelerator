# Architecture & Flow Diagrams

Scope: a **toy / prototype memory-side FPGA pipeline**. The FPGA does **not** run the LLM —
the PC runs distilgpt2 and exports quantized KV-cache slices; the FPGA prunes, compresses,
and restores them. The hero diagram is [`architecture.svg`](architecture.svg); the Mermaid
sources below render natively on GitHub and paste into slides via
[mermaid.live](https://mermaid.live).

Colour key: **blue** = PC / software · **purple** = UART / protocol ·
**green** = FPGA hardware · **orange** = metrics / results.

---

## 1. System architecture

```mermaid
flowchart LR
  subgraph PC["PC · Python Host — does NOT run on the FPGA"]
    direction TB
    A1["distilgpt2 inference"] --> A2["KV-cache slice export"]
    A2 --> A3["attention importance scoring (H2O)"]
    A3 --> A4["FP16 → INT8 quantization"]
    A4 --> A5["Python golden model (bit-exact reference)"]
  end
  subgraph LINK["UART · framed protocol · 921,600 baud"]
    direction TB
    U1["LOAD"] --> U2["RUN"] --> U3["GET_STATS / GET_DATA / GET_RESTORED"]
  end
  subgraph FPGA["Basys 3 FPGA · Artix-7 · 100 MHz"]
    direction TB
    F1["input slice BRAM"] --> F2["eviction + compression pipeline"]
    F2 --> F3["output BRAM"]
    F3 --> F4["hardware decompressor / restore"]
  end
  A4 -- "slice + commands" --> LINK
  LINK -- "framed bytes" --> F1
  F4 -- "stats / data / restored" --> LINK
  LINK -- "responses" --> A5

  classDef pc fill:#eef4fe,stroke:#1f6feb,color:#0a3069;
  classDef uart fill:#f5f0fd,stroke:#8250df,color:#512a8b;
  classDef fpga fill:#eaf5ec,stroke:#1a7f37,color:#0f5323;
  class A1,A2,A3,A4,A5 pc
  class U1,U2,U3 uart
  class F1,F2,F3,F4 fpga
```

---

## 2. FPGA internal pipeline

Store-and-forward, single 100 MHz clock domain, Verilog RTL, all memories inferred.
Each entry is **64 INT8 value bytes + 1 importance byte**; up to **512 entries** per slice.

```mermaid
flowchart TD
  I["input slice BRAM<br/>512 × (64 INT8 + 1 importance)"] --> E{"eviction filter<br/>importance ≥ threshold?"}
  E -- "drop" --> X["evicted (≈2 cycles)"]
  E -- "keep" --> D["delta encoder"]
  D --> R["zero-run RLE encoder"]
  R --> B{"bypass?<br/>compressed ≥ raw"}
  B -- "yes" --> RAW["store raw vector"]
  B -- "no" --> CMP["store compressed vector"]
  RAW --> O["output BRAM<br/>bitmap + stream"]
  CMP --> O
  O --> S["stats counters<br/>ratio · cycles · kept · bypass"]
  O --> DEC["hardware decompressor<br/>RLE⁻¹ → delta⁻¹"]
  DEC --> RES["restored vectors<br/>bit-exact, on demand"]

  classDef fpga fill:#eaf5ec,stroke:#1a7f37,color:#0f5323;
  classDef dec fill:#fff8e6,stroke:#bf8700,color:#6b4e00;
  classDef meta fill:#f0f3f6,stroke:#8c959f,color:#3d444d;
  class I,D,R,O,CMP,RAW,DEC,RES fpga
  class E,B dec
  class S,X meta
```

---

## 3. Verification flow

Correctness is defined once in the Python golden model; simulation and silicon are both
checked against it, byte-for-byte.

```mermaid
flowchart LR
  G["Python golden model<br/>reference encoder + decoder"] --> V["generated test vectors"]
  V --> T["8 self-checking<br/>Verilog testbenches"]
  T --> SP{"byte-exact?"}
  SP -- "yes" --> PASS1["simulation PASS"]
  SP -- "no" --> FIX["fix RTL"] --> T
  HW["bytes returned from<br/>FPGA over UART"] --> CHK{"equal to golden?"}
  G --> CHK
  CHK -- "yes" --> PASS2["hardware BIT-EXACT PASS<br/>compress + restore"]
  PASS1 --> CY{"sim cycles = silicon cycles?"}
  CY -- "238 = 238" --> DONE["verified: correct AND cycle-exact"]

  classDef pc fill:#eef4fe,stroke:#1f6feb,color:#0a3069;
  classDef res fill:#fdf0e6,stroke:#bc4c00,color:#7a3200;
  class G,V pc
  class T,SP,PASS1,FIX,HW,CHK,PASS2,CY,DONE res
```

---

## 4. Evaluation / results flow

```mermaid
flowchart TD
  EXP["export real distilgpt2<br/>KV-cache slice"] --> SW["threshold sweep on FPGA"]
  EXP --> AB["perplexity ablation (host)"]
  EXP --> MAP["layer / head evictability map"]
  SW --> R1["4.84× @ threshold 3<br/>81 / 402 kept → up to 22.3×"]
  AB --> R2["H2O + recency:<br/>+11% perplexity at 50% retention"]
  MAP --> R3["evictability concentrates<br/>in deep layers"]
  SW --> R4["finding: delta/RLE ≈ 0× on INT8 KV;<br/>savings come from eviction"]

  classDef pc fill:#eef4fe,stroke:#1f6feb,color:#0a3069;
  classDef fpga fill:#eaf5ec,stroke:#1a7f37,color:#0f5323;
  classDef res fill:#fdf0e6,stroke:#bc4c00,color:#7a3200;
  class EXP,AB,MAP pc
  class SW fpga
  class R1,R2,R3,R4 res
```
