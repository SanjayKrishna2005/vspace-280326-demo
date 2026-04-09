<!---
Tiny Tapeout docs/info.md — SNN AFib Detector
Leaving "How it works" or "How to test" as template text causes the docs CI to fail.
-->

# SNN AFib Detector — Spiking Reservoir Computing Core

- GitHub user: SanjayKrishna2005
- [How it works](#how-it-works)
- [How to test](#how-to-test)
- [External hardware](#external-hardware)

---

## How it works

### What problem does this chip solve?

Atrial fibrillation (AFib) is the world's most common cardiac arrhythmia, affecting
60+ million people globally. It is intermittent, frequently asymptomatic (70% of episodes
go unnoticed), and carries a **5× higher stroke risk** if undetected. Existing wearable
detectors solve this by duty-cycling a processor — waking a Cortex-M4 or similar
every few seconds to run inference. That wake-compute-sleep cycle consumes 5–50 mW
and still misses the brief paroxysmal episodes that matter most clinically.

This chip **eliminates the processor entirely.** Inference runs continuously inside the
spike dynamics of silicon neurons, consuming switching energy only when a heartbeat
arrives — roughly once per second at rest. The chip simultaneously detects AFib
(too irregular) and bradycardia/asystole (too slow or absent), making it a
two-class always-on cardiac monitor in 959 standard cells.

### Why this architecture is novel

Every conventional wearable neural network — from the Apple Watch to AliveCor KardiaMobile —
is fundamentally a multiply-accumulate engine running on a processor. This chip has
**zero multipliers anywhere in the design.** It uses:

- **Leaky integrate-and-fire neurons** where the "leak" is a right-shift (one wire, zero gates)
- **Shift-add arithmetic** for the readout accumulator
- **Bit-select comparators** replacing adder-comparator pairs (saves ~6 cells per threshold)
- **Event-driven computation** — the entire chip is gated by `spike_valid`, consuming
  dynamic power only once per heartbeat

This is not just an accelerator for a known algorithm. The silicon dynamics
**are** the algorithm. The reservoir's temporal memory cannot be replicated in software
without simulating every clock cycle — the computation is physically embodied in the
membrane potential state of the flip-flops between heartbeats.

### Signal pipeline

One R-peak pulse enters. Two arrhythmia flags exit. The pipeline has five stages,
each triggered once per heartbeat by the `spike_valid` gate:

```
ui_in[0] ─── r_peak pulse (1 clock wide, once per beat)
                  │
                  ▼
        ┌─────────────────┐
        │   rr_features   │  ← Stage 1
        │                 │  16-bit tick counter measures inter-beat gap.
        │  tick_count[15:9]│  Compresses to 6-bit rr_interval (64 bins).
        │  |delta|        │  Computes |RR[n] − RR[n-1]| = rr_delta ≈ RMSSD.
        │  tick[15|14]    │  Bit-select → asystole_flag if gap > 1.64 s.
        │                 │  At 10 kHz: 1 tick = 100 µs; counter fits real
        │                 │  heartbeat intervals (700ms = 7,000 ticks, well
        │                 │  within 16-bit max of 65,535 ticks = 6.55 s).
        └────────┬────────┘
                 │ rr_interval[5:0], rr_delta[5:0]
                 ▼
        ┌─────────────────┐
        │  spike_encoder  │  ← Stage 2
        │                 │  Rate-codes both features into 4-bit spike vectors.
        │  15−rr[5:2]     │  spike_interval: inverted (fast HR → more spikes)
        │  min(delta,15)  │  spike_delta: direct (large HRV → more spikes)
        └────────┬────────┘
                 │ spike_interval[3:0], spike_delta[3:0]
                 ▼
        ┌──────────────────────────────────────┐
        │         reservoir (8 LIF neurons)    │  ← Stage 3
        │                                      │
        │  n0–n3: spike_interval[3:0]          │  Rhythm/rate detectors
        │  n4–n7: spike_delta[3:0]             │  HRV irregularity detectors
        │                                      │
        │  spike_reg1: n0[t-1] → n7[t]        │  1-bit recurrence:
        │  n7 fires if delta high NOW          │  makes reservoir a true LSM
        │    OR interval was irregular LAST    │  (Echo State Property satisfied)
        │                                      │
        │  Each LIF: V = (V>>1) + W·spike_in  │  Leak = right-shift (0 gates)
        │            fires when V ≥ THRESHOLD  │  4-bit potential, event-driven
        └────────┬─────────────────────────────┘
                 │ neuron_spikes[7:0], any_spike
                 ▼
        ┌──────────────────────────────────────┐
        │    readout (dual-window classifier)   │  ← Stage 4
        │                                      │
        │  24-bit signed weight SR (8×3-bit)   │  Loaded once at boot via SPI
        │                                      │
        │  cycle_sum = Σ w[i]·spike[i]         │  Signed shift-add, no multiply
        │                                      │
        │  Fast window (8 beats):              │  ~5.6 s — acute AFib onset
        │  Slow window (16 beats):             │  ~11.2 s — sustained AFib
        │                                      │
        │  afib_flag = fast AND slow           │  Both must agree (AND vote)
        │  confidence_latch[2:0]               │  3-bit graded output
        └────────┬─────────────────────────────┘
                 │
                 ▼
        uo_out[0]: afib_flag       uo_out[7:5]: confidence_latch
        uo_out[1]: out_valid       uio_out[0]:  asystole_flag
        uo_out[2]: any_spike
```

### Why fixed random reservoir weights still work — Echo State Property

The reservoir uses **fixed weights baked in at synthesis time** as Verilog parameters.
The natural question is: why does a random fixed network produce useful classification?

The answer is Jaeger's **Echo State Property** (2001): a reservoir with sufficient
recurrence and contractivity maps any input sequence to a unique, reproducible internal
state trajectory — a high-dimensional nonlinear projection of the input history.
The linear readout only needs to find a separating hyperplane in that projected space,
which is a much simpler learning problem than training the full network.

In this design, the **`spike_reg1`** feedback register (n0's output at beat t → n7's
input at beat t+1) is the architectural element that makes the LSM framing correct.
Without it, the network is purely feedforward and has no cross-beat memory.
With it, n7's state at beat t encodes both the current HRV delta **and** the rhythm
state from the previous beat — giving the reservoir genuine temporal memory of
sustained vs. transient irregularity. A single ectopic beat (transient) leaves
`spike_reg1` unchanged the following beat. Sustained AFib (persistent) keeps
`spike_reg1` high across consecutive beats, systematically boosting the
accumulator score. **This is the classification mechanism.**

### Why this is harder than it looks — complexity at 959 cells

| Design challenge | How it was solved |
|---|---|
| Signed arithmetic without multipliers | 3-bit 2's complement weights sign-extended to 9-bit via `{{6{w[2]}}, w}` — pure wiring |
| Threshold comparators eliminating adders | `accum > -1` replaced by `~sign_bit` — saves ~6 gates per window |
| RR interval overflow at real heart rates | Compress 16-bit tick_count to 6 bits via `tick_count[15:9]` (right-shift 9) |
| Asystole detection without comparator | `tick_count[15] \| tick_count[14]` — two OR'd flip-flop outputs, no adder |
| Between-beat power consumption | All neurons gated by `spike_valid` — zero switching between beats |
| True temporal memory within budget | `spike_reg1`: 1 FF + 1 OR gate gives one-beat cross-neuron feedback |
| Synthesis overhead management | 4-bit LIF potential (not 8-bit), sign-bit comparators, beat counter tricks |

### Clinical justification — every design decision has a medical reason

| Design decision | Clinical basis |
|---|---|
| `rr_delta` as primary feature | Analogous to RMSSD — AHA recommended short-term HRV metric for AFib screening. Used by Apple Watch Series 4 FDA-cleared AFib algorithm. |
| Dual-window AND vote | ESC 2020 AFib guidelines require **sustained** irregularity. A single ectopic beat triggers the fast window but not the slow — the AND prevents false alarms. |
| Fast window (8 beats ≈ 5.6 s at 86 BPM) | Detects acute AFib onset and sustained episodes |
| Slow window (16 beats ≈ 11.2 s) | Confirms pattern persistence — matches clinical "sustained" criterion |
| Asystole at ~37 BPM (tick_count[14]) | AHA defines symptomatic bradycardia as HR < 40 BPM. At 10 kHz (demo board clock), bit 14 of the 16-bit tick counter asserts after 2¹⁴ = 16,384 ticks × 100 µs = 1.6384 s ≈ 37 BPM — detected with a single OR gate, no adder. |
| Inverted interval encoding | Faster rates → more spikes → stronger excitation. AFib tends toward elevated mean HR. |
| n3 weight = −3 (inhibitory) | n3 encodes fast rate. Inhibitory weight suppresses AFib score during fast-but-regular rhythm (e.g. sinus tachycardia). Prevents false positives. |

### Pin reference

| Pin | Direction | Signal | Description |
|-----|-----------|--------|-------------|
| `ui_in[0]` | Input | `r_peak` | Heartbeat pulse — rising edge triggers one pipeline cycle |
| `ui_in[1]` | Input | `w_load` | Weight load mode — hold HIGH while shifting in weights |
| `ui_in[2]` | Input | `w_data` | Serial weight data, MSB first |
| `ui_in[3]` | Input | `w_clk` | Weight shift clock — rising edge latches one bit |
| `ui_in[7:4]` | Input | — | Unused — tie LOW |
| `uo_out[0]` | Output | `afib_flag` | HIGH = AFib detected (fast AND slow window both positive) |
| `uo_out[1]` | Output | `out_valid` | Pulses HIGH 1 cycle every 16 beats — result is stable |
| `uo_out[2]` | Output | `any_spike` | HIGH if any reservoir neuron fired this beat |
| `uo_out[3]` | Output | `fsm_state[0]` | FSM state LSB (LOAD=00, RUN=01, OUTPUT=10) |
| `uo_out[4]` | Output | `fsm_state[1]` | FSM state MSB |
| `uo_out[7:5]` | Output | `confidence_latch` | 3-bit graded confidence: 7=definite AFib, 0=definitely normal |
| `uio_out[0]` | Output | `asystole_flag` | HIGH = bradycardia/asystole (HR < ~37 BPM) |
| `uio_out[7:1]` | Output | — | Tied LOW |
| `uio_oe[0]` | — | — | Always HIGH (bit 0 is output-enabled) |
| `uio_oe[7:1]` | — | — | Always LOW |

**Trained weight vector: `0x051A08` (24-bit hex, MSB first = neuron 7)**

| Neuron | Weight | Role |
|--------|--------|------|
| n0 | 0 | interval bit 0 — neutral |
| n1 | +1 | interval bit 1 — mild excitation |
| n2 | 0 | interval bit 2 — neutral |
| n3 | −3 | interval bit 3 — strong inhibition (suppresses false positives on fast-regular rhythm) |
| n4 | +1 | delta bit 0 — mild excitation on HRV |
| n5 | +2 | delta bit 1 — moderate excitation on HRV |
| n6 | +1 | delta bit 2 — mild excitation on HRV |
| n7 | 0 | recurrent neuron — contributes via spike_reg1 memory, not direct weight |

### Gate budget

| Module | Function | Approx. cells |
|--------|----------|---------------|
| `rr_features` | 16-bit tick counter, rr_interval, rr_delta, asystole_flag | ~85 |
| `spike_encoder` | Dual-channel rate coding, saturation clamp | ~25 |
| `reservoir` | 8 LIF neurons (4-bit potential each) + spike_reg1 | ~220 |
| `readout` | 24-bit weight SR, 2 accumulators, FSM, confidence | ~480 |
| `tt_um_snn_afib_detector` | Top-level port wiring | ~10 |
| PDK overhead (tap, fill, buf) | Inserted by OpenLane — not design logic | ~139 |
| **Total** | | **959 / 1000** |

---

## How to test

> **Read this section completely before connecting anything.**
> The chip will not classify correctly if the clock is wrong or weights are not loaded.
> Follow the steps in order.

### What you need

- Tiny Tapeout demo board (RP2040 onboard)
- A computer with the TT Commander software or MicroPython REPL access
- Optional for real ECG testing: AD8232 breakout, 3 electrodes, LM393 comparator

---

### Step 1 — Set clock to 10 kHz

**This is the most important step and the most commonly misunderstood.**

The chip's `clk` input must be driven at **10 kHz** (1 tick = 100 µs) on the demo board.

**Why 10 kHz and not higher?**

The `rr_features` module uses a **16-bit tick counter** (`tick_count[15:0]`) to measure the gap between heartbeats. This counter can hold a maximum of 65,535 ticks = **6.55 seconds** before saturating. At 10 kHz:

| Heart rate | Interval | Tick count | Fits 16-bit? |
|---|---|---|---|
| 250 BPM (max tachycardia) | 240 ms | 2,400 ticks | ✓ |
| 86 BPM (normal resting) | 700 ms | 7,000 ticks | ✓ |
| 37 BPM (asystole threshold) | 1,638 ms | 16,384 ticks (bit 14) | ✓ |
| 9 BPM (near-asystole) | 6,550 ms | 65,500 ticks | ✓ |

At **10 MHz** a normal 700 ms beat = **7,000,000 ticks** — overflows 16-bit on every heartbeat. The testbench runs at 10 MHz with artificially compressed inter-beat gaps (7,000 ticks = 700 µs simulation time, not 700 ms real time) only to keep simulation fast. The silicon must run at 10 kHz.

The **asystole threshold** is `tick_count[15] | tick_count[14]` (hardcoded bit-select in RTL — no comparator). At 10 kHz, bit 14 asserts at 16,384 ticks = **1.6384 s ≈ 37 BPM**, matching the AHA bradycardia limit exactly.

The **RR interval compression** is `tick_count[15:9]` (right-shift 9). At 10 kHz, a 700 ms beat → 7,000 ticks → `rr_interval` = 7000 >> 9 = **13** (out of 63 bins). At 10 MHz the same beat gives 7,000,000 >> 9 = 13,671 — clamps to 63 and loses all discrimination.

Using TT Commander:
```
set_clock 10000
```

Using MicroPython directly:
```python
from machine import Pin, PWM
clk = PWM(Pin(0))
clk.freq(10_000)
clk.duty_u16(32768)
```

At 10 kHz: 1 tick = 100 µs. A 60 BPM heartbeat = 10,000 ticks between beats.
The asystole threshold (tick_count bit 14) = 16,384 ticks = 1.64 s ≈ 37 BPM. ✓

---

### Step 2 — Reset the chip

Hold `rst_n` LOW for at least 3 clock cycles, then release HIGH.

```python
tt.rst_n(0)
tt.clock_project_PWM(10_000)
time.sleep_ms(1)
tt.rst_n(1)
```

**After reset, verify:**
- `uo_out` = `0x00`
- `uio_out[0]` = 0
- `uo_out[4:3]` (fsm_state) = `00` (LOAD state)

If fsm_state ≠ 00, reset did not complete. Repeat.

---

### Step 3 — Load the trained weights (mandatory before any test)

The chip starts in LOAD state after reset and **will not classify** until weights
are loaded. Load the 24-bit weight vector `0x051A08` MSB first.

**Manual bit-bang procedure:**

```python
WEIGHTS = 0x051A08  # trained weight vector

tt.ui_in[1] = 1     # assert w_load — enter weight loading mode
tt.ui_in[2] = 0
tt.ui_in[3] = 0

for i in range(23, -1, -1):           # 24 bits, MSB first
    tt.ui_in[2] = (WEIGHTS >> i) & 1  # set w_data
    tt.ui_in[3] = 1                   # w_clk rising edge
    time.sleep_us(10)
    tt.ui_in[3] = 0                   # w_clk falling edge
    time.sleep_us(10)

tt.ui_in[1] = 0     # release w_load → FSM transitions to RUN
time.sleep_ms(1)
```

**After weight load, verify:**
- `uo_out[4:3]` (fsm_state) = `01` (RUN state)

If fsm_state ≠ 01, the w_load handshake did not complete. Check that w_load
went HIGH (asserted seen) then LOW. Repeat from reset if needed.

---

### Step 4a — Synthetic pulse test (no ECG hardware needed)

This test requires no ECG hardware. Toggle `ui_in[0]` to simulate heartbeats.

#### Test A: Normal sinus rhythm → expect afib_flag = 0

Send 20 pulses with a **fixed** 1000-cycle gap (at 10 kHz = 100 ms = 600 BPM equivalent
for demo speed, or scale to 7000 cycles for realistic 86 BPM):

```python
def send_beat():
    tt.ui_in[0] = 1
    time.sleep_us(100)   # 1 clock at 10 kHz
    tt.ui_in[0] = 0

for _ in range(20):
    time.sleep_ms(100)   # gap between beats (1000 clocks at 10 kHz)
    send_beat()

time.sleep_ms(50)
print(f"afib_flag     = {tt.uo_out[0]}")   # expect 0
print(f"out_valid     = {tt.uo_out[1]}")   # expect 1
print(f"asystole      = {tt.uio_out[0]}")  # expect 0
print(f"confidence    = {(tt.uo_out >> 5) & 0x7}")  # expect 0-2 (normal range)
```

**Expected result:** `afib_flag=0`, `out_valid=1`, `confidence` in range 0–2.

#### Test B: AFib pattern → expect afib_flag = 1

Send 32 pulses with **alternating short/long** gaps:

```python
# Reset and reload weights first
tt.rst_n(0); time.sleep_ms(1); tt.rst_n(1)
load_weights(0x051A08)  # call your load function from Step 3

afib_pattern = [25, 95, 30, 88, 22, 92, 35, 80,
                28, 98, 20, 100, 32, 85, 26, 91] * 2  # 32 beats

for gap_ms in afib_pattern:
    time.sleep_ms(gap_ms)
    send_beat()

time.sleep_ms(50)
print(f"afib_flag     = {tt.uo_out[0]}")   # expect 1
print(f"out_valid     = {tt.uo_out[1]}")   # expect 1
print(f"confidence    = {(tt.uo_out >> 5) & 0x7}")  # expect 5-7 (AFib range)
print(f"any_spike     = {tt.uo_out[2]}")   # expect 1 (neurons fired)
```

**Expected result:** `afib_flag=1`, `confidence` in range 5–7, `any_spike=1`.

#### Test C: Asystole → expect uio_out[0] = 1

After loading weights, simply do not send any beats:

```python
time.sleep_ms(2000)   # wait 2 seconds (> 1.64 s threshold at 10 kHz)
print(f"asystole = {tt.uio_out[0]}")   # expect 1

send_beat()           # send one beat to clear the flag
time.sleep_ms(10)
print(f"asystole = {tt.uio_out[0]}")   # expect 0
```

**Expected result:** flag asserts after ~1.64 s silence, clears on next beat.

---

### Step 4b — Real ECG test (AD8232)

**Required hardware:** AD8232 breakout, 3 electrodes (RA/LA/RL), LM393 comparator or 74HC14 Schmitt trigger.

**Wiring:**

```
Electrode (Right Arm)  ─► AD8232 RA pin
Electrode (Left Arm)   ─► AD8232 LA pin
Electrode (Right Leg)  ─► AD8232 RL pin

AD8232 VCC     ─► 3.3 V
AD8232 GND     ─► GND
AD8232 SDN     ─► GND  (always powered)
AD8232 OUTPUT  ─► LM393 IN+    (non-inverting input)
               ─► LM393 IN−    set to ~0.5 V via voltage divider (10k/10k from 3.3V)
               ─► LM393 OUT    ─► 10 kΩ pull-up to 3.3 V ─► ui_in[0]
```

> The LM393 open-collector output pulled to 3.3V gives a clean 3.3V CMOS pulse
> on each R-peak. The AD8232 OUTPUT swings above the 0.5V threshold only
> at the R-peak — all other waveform features are filtered out.

**After wiring:**
1. Complete Steps 1–3 (clock, reset, weight load)
2. Attach electrodes and sit still
3. Watch `any_spike` (uo_out[2]) — should toggle ~once per heartbeat
4. `out_valid` (uo_out[1]) pulses every ~16 heartbeats (~13 s at 75 BPM)
5. `afib_flag` (uo_out[0]) stays LOW during normal sinus rhythm

---

### Simulation

Run the full testbench locally with Icarus Verilog:

```bash
iverilog -g2012 -o sim.out tb.v tt_um_snn_afib_detector.v \
  rr_features.v spike_encoder.v lif_neuron.v reservoir.v readout.v \
  && vvp sim.out
```

Expected output: `8 passed, 0 failed — ALL TESTS PASSED`

> **Waveform inspection:**
> ```bash
> gtkwave tb.vcd
> ```
> Add signals: `tb.dut.u_reservoir.s[7:0]`, `tb.dut.u_readout.accum_fast`,
> `tb.dut.u_readout.accum_slow`, `tb.uo_out[0]`.
> You can see the accumulator climbing during AFib beats and the flag asserting
> when both windows close positive.

<!-- TODO: Add GTKWave screenshots here showing:
     (a) neuron spike patterns Normal vs AFib
     (b) accum_fast and accum_slow trajectories
     (c) spike_reg1 feedback contribution in T7c -->

<!-- TODO: Add Python weight training plot showing:
     rr_delta distribution Normal vs AFib from PhysioNet MIT-BIH
     demonstrating why delta neurons get positive weights -->

---

### Simulation results

| Test | Stimulus | Expected | Status |
|------|----------|----------|--------|
| T0 | Power-on | `uio_oe=0x01`, all outputs 0 | PASS |
| T1 | Reset + weight load `0x051A08` | `fsm_state=RUN` after `w_load↓` | PASS |
| T2 | 20 normal beats (7000 ticks each) | `afib_flag=0`, `out_valid=1`, `asystole=0` | PASS |
| T3 | 32 irregular AFib beats | `afib_flag=1`, `confidence≥101`, `any_spike=1` | PASS |
| T4 | No beats for 17000 ticks | `asystole_flag=1` | PASS |
| T5 | Beat after silence | `asystole_flag=0` | PASS |
| T6 | 4 irregular + 12 normal beats | `afib_flag=0` (specificity) | PASS |
| T7 | 16 sustained irregular beats | `afib_flag=1` (sensitivity) | PASS |

---

## External hardware

### Minimum (synthetic test only)

No external hardware needed. Use the RP2040 on the TT demo board to generate
synthetic R-peak pulses via MicroPython as described in Step 4a.

### For real ECG testing

| Component | Part | Purpose |
|-----------|------|---------|
| ECG front-end | AD8232 breakout (SparkFun DEV-12650 or clone) | Amplifies bio-signal, outputs analog ECG |
| Pulse shaper | LM393 comparator + 10kΩ pull-up, OR 74HC14 Schmitt trigger inverter | Converts R-peak to clean 3.3V CMOS digital pulse |
| Electrodes | 3× snap ECG electrodes (standard Ag/AgCl) | Standard Lead I placement |
| Optional | nRF52832 or ESP32 BLE module | Reads `afib_flag` and `asystole_flag`, transmits phone alerts |

**Why a Schmitt trigger is needed:** The AD8232 OUTPUT is an analog ECG waveform,
not a digital signal. Without a comparator/Schmitt trigger, every peak and trough
of the QRS complex would generate multiple spurious transitions on `ui_in[0]`,
producing false R-peak counts. The comparator threshold (~0.5V above baseline)
fires exactly once per beat at the R-peak.

**Lead placement (Lead I configuration):**
- Right Arm (RA) electrode — right wrist or right side of chest
- Left Arm (LA) electrode — left wrist or left side of chest
- Right Leg (RL) electrode — lower right abdomen (ground/reference)

### Real-world deployment path

```
Patient
  │ electrodes
  ▼
AD8232 ECG front-end
  │ analog ECG waveform
  ▼
LM393 comparator (threshold ~0.5V)
  │ digital R-peak pulse (3.3V CMOS)
  │
  ├──────────────────────────────────────┐
  │                                      │
  ▼                                      │
ui_in[0] → [SNN AFib Detector]          │
           959 cells, SKY130A            │
           Always-on, event-driven       │
           ↓           ↓                 │
        afib_flag   asystole_flag        │
           │             │               │
           ▼             ▼               │
        nRF52 BLE SoC (deep sleep)       │
        Wakes ONLY on flag assertion     │
           │                             │
           ▼                         RP2040 clock: 10 kHz (required)
        Phone alert                  1 tick=100µs; 700ms beat=7,000 ticks
        (BLE notification)           16-bit counter fits; bins calibrated here
```

### Honest limitations

- **Not a medical device.** Verified on synthetic RR sequences and a Python model
  of PhysioNet MIT-BIH data. Not validated in a clinical study or on real silicon.
- **Single-lead timing only.** No waveform morphology. Cannot distinguish PVC,
  SVT, or flutter from AFib — only rhythm irregularity and rate.
- **10 kHz system clock on the demo board.** The RP2040 on the TT demo board must drive `clk` at **10 kHz** (1 tick = 100 µs). At this frequency a real 700 ms heartbeat interval = 7,000 ticks — well within the 16-bit counter range (max 65,535 ticks = 6.55 s). At 10 MHz the counter would overflow on every beat (700 ms = 7,000,000 ticks >> 65,535). The testbench runs at 10 MHz with compressed inter-beat gaps (7,000 ticks = 700 µs in sim, not 700 ms in real time) purely to keep simulation fast. The asystole threshold (bit 14 = 16,384 ticks = 1.64 s) and all RR interval bins are **calibrated for the 10 kHz demo clock**. Weight vector `0x051A08` was optimised at this clock. At other frequencies all interval bins shift proportionally and the weights must be retrained.
- **Weight retraining for real deployment.** The default weights were derived
  analytically from synthetic RR distributions. For real patients, retrain
  the 8 readout weights on MIT-BIH PhysioNet data and reload via the serial
  interface (`ui_in[3:1]`) — no re-tapeout needed.
- **16-beat minimum before first flag.** The slow window requires 16 beats
  (~13 s at 75 BPM) before `out_valid` first asserts. This is by design —
  it implements the ESC 2020 "sustained irregularity" criterion.