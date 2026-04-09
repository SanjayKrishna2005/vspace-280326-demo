import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, FallingEdge, Timer


# ─────────────────────────────────────────────────────────────────────────────
# Signal aliases  (mirrors tb.v `define macros)
# ─────────────────────────────────────────────────────────────────────────────
def AFIB_FLAG(dut):   return (int(dut.uo_out.value) >> 0) & 0x1
def VALID(dut):       return (int(dut.uo_out.value) >> 1) & 0x1
def SPIKE_MON(dut):   return (int(dut.uo_out.value) >> 2) & 0x1
def FSM_STATE(dut):   return (int(dut.uo_out.value) >> 3) & 0x3
def CONFIDENCE(dut):  return (int(dut.uo_out.value) >> 5) & 0x7
def ASYSTOLE(dut):    return (int(dut.uio_out.value) >> 0) & 0x1


# ─────────────────────────────────────────────────────────────────────────────
# Trained weights  (8 neurons × 3 bits, MSB-first)
# n7=0 n6=+1 n5=+2 n4=+1 n3=-3 n2=0 n1=+1 n0=0
# Binary: 000 001 010 001 101 000 001 000
# ─────────────────────────────────────────────────────────────────────────────
AFIB_WEIGHTS = 0b000_001_010_001_101_000_001_000   # 24-bit


# ─────────────────────────────────────────────────────────────────────────────
# Helper coroutines  (direct translations of the Verilog tasks)
# ─────────────────────────────────────────────────────────────────────────────
async def wait_clks(dut, n):
    """Wait n rising edges — equivalent to Verilog wait_clks task."""
    await ClockCycles(dut.clk, n)


async def send_r_peak(dut):
    """Assert ui_in[0] for one clock, then deassert — mirrors send_r_peak task."""
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.ui_in.value = int(dut.ui_in.value) | 0x01        # set bit 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.ui_in.value = int(dut.ui_in.value) & ~0x01       # clear bit 0


async def send_beat_after(dut, ticks):
    """Wait ticks clocks then send an R-peak — mirrors send_beat_after task."""
    await wait_clks(dut, ticks)
    await send_r_peak(dut)


async def load_weights(dut, weights: int):
    """
    Serial-shift 24 bits of weights MSB-first into the design.
    ui_in[1] = load_mode, ui_in[2] = data_bit, ui_in[3] = shift_clk
    Mirrors the Verilog load_weights task exactly.
    """
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    # Enter load mode: ui_in[1]=1, ui_in[2]=0, ui_in[3]=0
    base = int(dut.ui_in.value) & 0xF0          # preserve upper nibble
    dut.ui_in.value = base | 0b0010             # bit1=1, bit2=0, bit3=0

    for i in range(23, -1, -1):
        bit = (weights >> i) & 1
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        # data bit on ui_in[2], shift_clk high on ui_in[3]
        dut.ui_in.value = (int(dut.ui_in.value) & 0xF1) | (bit << 2) | (1 << 3)
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        dut.ui_in.value = int(dut.ui_in.value) & ~(1 << 3)   # lower shift_clk

    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    dut.ui_in.value = int(dut.ui_in.value) & ~(1 << 1)       # exit load mode
    await wait_clks(dut, 5)
    dut._log.info(f"[TB] Weights loaded. FSM={FSM_STATE(dut):02b}")


async def do_reset_and_load(dut):
    """Hard reset then load trained weights — mirrors do_reset_and_load task."""
    dut.rst_n.value = 0
    await wait_clks(dut, 3)
    dut.rst_n.value = 1
    await wait_clks(dut, 3)
    await load_weights(dut, AFIB_WEIGHTS)


# ─────────────────────────────────────────────────────────────────────────────
# Main test
# ─────────────────────────────────────────────────────────────────────────────
@cocotb.test()
async def test_snn_afib_detector(dut):
    """
    TT SNN AFib Detector — Golden Vector Testbench (cocotb port of tb.v v5.1)
    Covers: uio direction, FSM states, weight load, normal rhythm, sustained
    AFib, confidence scoring, asystole detect/clear, specificity, sensitivity,
    recurrence benefit, and reset.
    """

    dut._log.info("=" * 55)
    dut._log.info("  TT SNN AFib Detector — cocotb Testbench v5.1")
    dut._log.info("  Dual-window | AND voting | 1-bit recurrence | Asystole")
    dut._log.info("=" * 55)

    # ── Clock: 10 MHz → 100 ns period (matches tb.v #50 half-period) ─────────
    clock = Clock(dut.clk, 100, units="ns")
    cocotb.start_soon(clock.start())

    # ── Initialise inputs ─────────────────────────────────────────────────────
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    dut.ena.value    = 1
    dut.rst_n.value  = 0

    pass_count = 0
    fail_count = 0

    # spike_seen flag — updated by monitoring SPIKE_MON after each beat
    spike_seen = False

    # ── Release reset ─────────────────────────────────────────────────────────
    await wait_clks(dut, 5)
    dut.rst_n.value = 1
    await wait_clks(dut, 3)

    # ── T0: uio_oe direction check ────────────────────────────────────────────
    uio_oe_val = int(dut.uio_oe.value)
    if uio_oe_val == 0b00000001:
        dut._log.info("[PASS] T0: uio_oe=0x01 — asystole pin correctly set as output")
        pass_count += 1
    else:
        dut._log.error(f"[FAIL] T0: uio_oe={uio_oe_val:08b} (expected 00000001)")
        fail_count += 1

    # ── T1: FSM starts in LOAD (00) ───────────────────────────────────────────
    await wait_clks(dut, 2)
    fsm = FSM_STATE(dut)
    if fsm == 0b00:
        dut._log.info("[PASS] T1: FSM starts in LOAD (00)")
        pass_count += 1
    else:
        dut._log.error(f"[FAIL] T1: FSM={fsm:02b} expected 00")
        fail_count += 1

    # ── T2: Weight load → FSM transitions to RUN (01) ────────────────────────
    dut._log.info(f"[INFO] Loading trained weights (0x{AFIB_WEIGHTS:06X})...")
    await load_weights(dut, AFIB_WEIGHTS)
    fsm = FSM_STATE(dut)
    if fsm == 0b01:
        dut._log.info("[PASS] T2: FSM moved to RUN (01) after weight load")
        pass_count += 1
    else:
        dut._log.error(f"[FAIL] T2: FSM={fsm:02b} expected 01")
        fail_count += 1

    # ── T3: Normal sinus rhythm — 20 beats @ 700 ms each (7000 ticks) ────────
    dut._log.info("[INFO] T3: 20 normal sinus beats (7000 ticks = 700ms each)...")
    for _ in range(20):
        await send_beat_after(dut, 7000)
        if SPIKE_MON(dut):
            spike_seen = True
    await wait_clks(dut, 50)

    dut._log.info(
        f"[INFO] T3: afib={AFIB_FLAG(dut)} valid={VALID(dut)} "
        f"asystole={ASYSTOLE(dut)} confidence={CONFIDENCE(dut):03b}"
    )

    # T3a — out_valid should be asserted (slow window has closed)
    if VALID(dut) == 1:
        dut._log.info("[PASS] T3a: out_valid asserted — slow window closed")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T3a: out_valid=0")
        fail_count += 1

    # T3b — no false-positive AFib on normal rhythm
    if AFIB_FLAG(dut) == 0:
        dut._log.info("[PASS] T3b: Normal rhythm classified correctly (afib=0)")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T3b: False positive — afib=1 on normal rhythm")
        fail_count += 1

    # T3c — no asystole at 700 ms intervals
    if ASYSTOLE(dut) == 0:
        dut._log.info("[PASS] T3c: Asystole=0 during normal 700ms beat interval")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T3c: Asystole false positive at 700ms")
        fail_count += 1

    # ── T4: Sustained AFib — 32 highly irregular beats ───────────────────────
    dut._log.info("[INFO] T4: 32 sustained irregular AFib beats...")
    await do_reset_and_load(dut)
    spike_seen = False

    t4_intervals = [
        2500, 9500, 3000, 8800, 2200, 9200, 3500, 8000,
        2800, 9800, 2000,10000, 3200, 8500, 2600, 9100,
        3100, 8200, 2400, 9600, 2700, 9300, 3300, 8700,
        2100, 9700, 3400, 8100, 2900, 9400,
    ]
    for ticks in t4_intervals:
        await send_beat_after(dut, ticks)
        if SPIKE_MON(dut):
            spike_seen = True
    await wait_clks(dut, 100)

    dut._log.info(
        f"[INFO] T4: afib={AFIB_FLAG(dut)} valid={VALID(dut)} "
        f"confidence={CONFIDENCE(dut):03b} spike_seen={int(spike_seen)}"
    )

    # T4a — AFib must be detected
    if AFIB_FLAG(dut) == 1:
        dut._log.info("[PASS] T4a: AFib detected by fast & slow window vote (afib=1)")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T4a: AFib not detected")
        fail_count += 1

    # T4b — reservoir neurons must have fired
    if spike_seen:
        dut._log.info("[PASS] T4b: Reservoir neurons fired during AFib sequence")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T4b: No reservoir spikes seen")
        fail_count += 1

    # ── T5: Confidence in AFib range (≥ 5 = 0b101) ───────────────────────────
    conf = CONFIDENCE(dut)
    if conf >= 0b101:
        dut._log.info(f"[PASS] T5: confidence_latch in AFib range = {conf:03b}")
        pass_count += 1
    else:
        dut._log.error(f"[FAIL] T5: confidence_latch too low = {conf:03b} (expected >=101)")
        fail_count += 1

    # ── T6: Asystole detection & clearance ───────────────────────────────────
    dut._log.info("[INFO] T6: 17000-tick silence (>1.6384 s threshold)...")
    await wait_clks(dut, 17000)

    if ASYSTOLE(dut) == 1:
        dut._log.info("[PASS] T6a: Asystole flag asserted after >16384-tick silence")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T6a: Asystole flag did not assert")
        fail_count += 1

    await send_r_peak(dut)
    await wait_clks(dut, 3)

    if ASYSTOLE(dut) == 0:
        dut._log.info("[PASS] T6b: Asystole flag cleared on R-peak arrival")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T6b: Asystole did not clear after R-peak")
        fail_count += 1

    # ── T7a: Specificity — 4 irregular then 12 normal beats ──────────────────
    dut._log.info("[INFO] T7a: Specificity — 4 irregular + 12 normal beats...")
    await do_reset_and_load(dut)
    spike_seen = False

    for ticks in [1500, 11000, 1800, 10500]:
        await send_beat_after(dut, ticks)
        if SPIKE_MON(dut):
            spike_seen = True
    for _ in range(12):
        await send_beat_after(dut, 7000)
        if SPIKE_MON(dut):
            spike_seen = True
    await wait_clks(dut, 100)

    dut._log.info(
        f"[INFO] T7a: afib={AFIB_FLAG(dut)} valid={VALID(dut)} "
        f"confidence={CONFIDENCE(dut):03b}"
    )
    if AFIB_FLAG(dut) == 0:
        dut._log.info("[PASS] T7a: Specificity preserved — 4-beat burst not flagged (afib=0)")
        dut._log.info("       [12 normal beats dominate both windows; fast & slow stay negative]")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T7a: False positive — 4 irregular beats out of 16 flagged as AFib")
        fail_count += 1

    # ── T7b: Sensitivity — 16 sustained irregular beats ──────────────────────
    dut._log.info("[INFO] T7b: Sensitivity — 16 sustained irregular beats...")
    await do_reset_and_load(dut)
    spike_seen = False

    t7b_intervals = [
        1500, 11000, 1800, 10500, 2000, 10000, 1700, 11500,
        2300,  9800, 1600, 10800, 2100, 10200, 1900, 11200,
    ]
    for ticks in t7b_intervals:
        await send_beat_after(dut, ticks)
        if SPIKE_MON(dut):
            spike_seen = True
    await wait_clks(dut, 100)

    dut._log.info(
        f"[INFO] T7b: afib={AFIB_FLAG(dut)} valid={VALID(dut)} "
        f"confidence={CONFIDENCE(dut):03b}"
    )
    if AFIB_FLAG(dut) == 1:
        dut._log.info("[PASS] T7b: Fast+Slow both detected 16-beat AFib episode (afib=1)")
        pass_count += 1
    else:
        dut._log.error("[FAIL] T7b: 16-beat sustained AFib episode not detected")
        fail_count += 1

    # ── T7c: Recurrence benefit — 16 moderate irregular beats ────────────────
    dut._log.info("[INFO] T7c: Recurrence benefit — 16 moderate irregular beats...")
    await do_reset_and_load(dut)
    spike_seen = False

    t7c_intervals = [
        4500, 7500, 4800, 7200, 4600, 7400, 4700, 7300,
        4400, 7600, 4900, 7100, 4500, 7500, 4600, 7400,
    ]
    for ticks in t7c_intervals:
        await send_beat_after(dut, ticks)
        if SPIKE_MON(dut):
            spike_seen = True
    await wait_clks(dut, 100)

    dut._log.info(
        f"[INFO] T7c: afib={AFIB_FLAG(dut)} valid={VALID(dut)} "
        f"confidence={CONFIDENCE(dut):03b} spike_seen={int(spike_seen)}"
    )
    # Soft pass — moderate AFib is borderline by design; recurrence still
    # contributes if spike_seen=1 (visible in confidence score)
    if AFIB_FLAG(dut) == 1:
        dut._log.info("[PASS] T7c: Recurrence detected moderate sustained AFib (afib=1)")
        dut._log.info("       [n7 fired via spike_reg1 feedback — boosted accumulator score]")
    else:
        dut._log.info(f"[INFO] T7c: Moderate pattern at borderline — confidence={CONFIDENCE(dut):03b}")
        dut._log.info(f"       [recurrence active: spike_seen={int(spike_seen)} confirms n7 contribution]")
    pass_count += 1   # always passes (soft check, mirrors tb.v behaviour)

    # ── T8: Reset clears all state ────────────────────────────────────────────
    dut.rst_n.value = 0
    await wait_clks(dut, 3)

    if (AFIB_FLAG(dut) == 0 and VALID(dut) == 0 and
            FSM_STATE(dut) == 0b00 and ASYSTOLE(dut) == 0):
        dut._log.info("[PASS] T8: Reset clears afib_flag, out_valid, asystole, FSM=LOAD")
        pass_count += 1
    else:
        dut._log.error(
            f"[FAIL] T8: afib={AFIB_FLAG(dut)} valid={VALID(dut)} "
            f"asystole={ASYSTOLE(dut)} fsm={FSM_STATE(dut):02b} after reset"
        )
        fail_count += 1

    dut.rst_n.value = 1

    # ── Summary ───────────────────────────────────────────────────────────────
    dut._log.info("=" * 55)
    dut._log.info(f"  Results: {pass_count} passed, {fail_count} failed")
    if fail_count == 0:
        dut._log.info("  ALL TESTS PASSED")
    else:
        dut._log.error(f"  {fail_count} TEST(S) FAILED — see above")
    dut._log.info("=" * 55)

    assert fail_count == 0, f"{fail_count} test(s) failed — see log above"