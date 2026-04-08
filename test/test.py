"""
cocotb testbench for tt_um_snn_afib_detector
Tiny Tapeout SNN AFib Detector — Triple-window | 2-of-3 voting | Asystole detect

Mirrors the logic of tb.v exactly so both flows produce the same results.
Run with:
    cd test && make
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, FallingEdge, Timer


# ── Constants (must match tb.v / readout.v) ──────────────────────────────────
AFIB_WEIGHTS = 0x088051A08   # 33-bit: n10=+2 n9=+1 n8=0 n7=0 n6=+1
                              #         n5=+2 n4=+1 n3=-3 n2=0 n1=+1 n0=0
CLK_PERIOD_NS = 100           # 10 MHz → 100 ns period


# ── Reference model ───────────────────────────────────────────────────────────
class AfibDetectorModel:
    """
    Software golden reference that mirrors the chip's observable outputs.
    Tracks only what we can actually assert from outside the chip:
      - FSM state transitions (LOAD=0, RUN=1, OUTPUT=2)
      - asystole_flag asserts after >16384 ticks without R-peak
      - out_valid pulses every 16 beats once in RUN
    """
    LOAD   = 0b00
    RUN    = 0b01
    OUTPUT = 0b10

    def __init__(self):
        self.fsm_state    = self.LOAD
        self.weights_seen = False
        self.beat_count   = 0
        self.tick_count   = 0
        self.asystole     = False

    def reset(self):
        self.fsm_state    = self.LOAD
        self.weights_seen = False
        self.beat_count   = 0
        self.tick_count   = 0
        self.asystole     = False

    def load_weights(self):
        """Simulate w_load pulse → FSM moves LOAD→RUN."""
        self.fsm_state    = self.RUN
        self.beat_count   = 0
        self.weights_seen = True

    def r_peak(self):
        """Simulate an R-peak arriving."""
        self.tick_count  = 0
        self.asystole    = False
        self.beat_count += 1

    def tick(self, n=1):
        """Advance tick_count by n clocks (no R-peak)."""
        self.tick_count += n
        if self.tick_count >= 16384:
            self.asystole = True

    def out_valid_expected_after_beats(self, n):
        """Returns True if we expect out_valid after n beats since last reset."""
        return (n > 0) and (n % 16 == 0)


# ── Helpers ───────────────────────────────────────────────────────────────────
async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.ena.value   = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def load_weights(dut, weights: int):
    """
    Serial-load 33 bits into the readout weight shift register.
    Protocol: assert w_load, clock in bits MSB-first on w_clk rising edges,
    then deassert w_load → FSM transitions LOAD→RUN.
    Matches tb.v load_weights task exactly.
    """
    # Assert w_load (ui_in[1])
    dut.ui_in.value = 0b00000010
    await ClockCycles(dut.clk, 1)

    for i in range(32, -1, -1):
        bit = (weights >> i) & 1
        # w_data=bit (ui_in[2]), w_clk=1 (ui_in[3]), w_load=1 (ui_in[1])
        dut.ui_in.value = 0b00000010 | (bit << 2) | (1 << 3)
        await ClockCycles(dut.clk, 1)
        # w_clk low
        dut.ui_in.value = 0b00000010 | (bit << 2)
        await ClockCycles(dut.clk, 1)

    # Deassert w_load → triggers LOAD→RUN transition
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 5)


async def send_r_peak(dut):
    """Pulse r_peak (ui_in[0]) for exactly 1 clock. Matches tb.v send_r_peak."""
    dut.ui_in.value = dut.ui_in.value | 0b00000001
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = dut.ui_in.value & ~0b00000001
    await ClockCycles(dut.clk, 1)


async def send_beat_after(dut, ticks: int):
    """Wait ticks clocks, then send an R-peak pulse. Matches tb.v send_beat_after."""
    await ClockCycles(dut.clk, ticks)
    await send_r_peak(dut)


async def do_reset_and_load(dut):
    """Full reset + weight load sequence used before each test scenario."""
    await reset_dut(dut)
    await load_weights(dut, AFIB_WEIGHTS)


def fsm_state(dut) -> int:
    return (int(dut.uo_out.value) >> 3) & 0b11

def afib_flag(dut) -> int:
    return int(dut.uo_out.value) & 0b00000001

def out_valid(dut) -> int:
    return (int(dut.uo_out.value) >> 1) & 1

def any_spike(dut) -> int:
    return (int(dut.uo_out.value) >> 2) & 1

def confidence(dut) -> int:
    return (int(dut.uo_out.value) >> 5) & 0b111

def asystole_flag(dut) -> int:
    return int(dut.uio_out.value) & 0b00000001


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_t0_uio_direction(dut):
    """T0: uio_oe[0]=1 (asystole output), uio_oe[7:1]=0 (inputs)."""
    dut._log.info("T0: Checking uio_oe direction register")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    uio_oe = int(dut.uio_oe.value)
    assert uio_oe == 0b00000001, \
        f"T0 FAIL: uio_oe={bin(uio_oe)}, expected 0b00000001"
    dut._log.info("T0 PASS: uio_oe=0b00000001 — asystole pin correctly set as output")


@cocotb.test()
async def test_t1_fsm_starts_in_load(dut):
    """T1: After reset, FSM must be in LOAD state (00)."""
    dut._log.info("T1: FSM initial state check")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    model = AfibDetectorModel()
    await reset_dut(dut)
    model.reset()

    await ClockCycles(dut.clk, 2)
    state = fsm_state(dut)
    assert state == model.LOAD, \
        f"T1 FAIL: FSM={bin(state)}, expected LOAD (00)"
    dut._log.info(f"T1 PASS: FSM starts in LOAD (00)")


@cocotb.test()
async def test_t2_weight_load_transitions_fsm(dut):
    """T2: After serial weight load, FSM must move to RUN (01)."""
    dut._log.info("T2: Weight load → FSM RUN transition")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    model = AfibDetectorModel()
    await reset_dut(dut)
    model.reset()

    dut._log.info(f"Loading weights: 0x{AFIB_WEIGHTS:09X}")
    await load_weights(dut, AFIB_WEIGHTS)
    model.load_weights()

    state = fsm_state(dut)
    assert state == model.RUN, \
        f"T2 FAIL: FSM={bin(state)}, expected RUN (01)"
    dut._log.info("T2 PASS: FSM moved to RUN (01) after weight load")


@cocotb.test()
async def test_t3_normal_sinus_rhythm(dut):
    """
    T3: 20 normal sinus beats at 7000 ticks each (700ms, ~86 BPM).
    Expected: afib=0, out_valid=1, asystole=0.
    """
    dut._log.info("T3: Normal sinus rhythm — 20 beats at 700ms each")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await do_reset_and_load(dut)

    for _ in range(20):
        await send_beat_after(dut, 7000)

    await ClockCycles(dut.clk, 50)

    valid = out_valid(dut)
    afib  = afib_flag(dut)
    asys  = asystole_flag(dut)
    conf  = confidence(dut)

    dut._log.info(f"T3: afib={afib} valid={valid} asystole={asys} confidence={bin(conf)}")

    assert valid == 1, f"T3a FAIL: out_valid=0 — slow window did not close"
    dut._log.info("T3a PASS: out_valid=1 — slow window closed correctly")

    assert afib == 0, f"T3b FAIL: False positive — afib=1 on normal rhythm"
    dut._log.info("T3b PASS: Normal rhythm classified correctly (afib=0)")

    assert asys == 0, f"T3c FAIL: Asystole false positive at 700ms inter-beat interval"
    dut._log.info("T3c PASS: asystole=0 during normal 700ms beat interval")


@cocotb.test()
async def test_t4_sustained_afib(dut):
    """
    T4: 32 sustained irregular AFib beats (alternating short/long intervals).
    Expected: afib=1, any_spike=1, confidence >= 101 (5).
    """
    dut._log.info("T4: Sustained AFib — 32 irregular beats")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await do_reset_and_load(dut)

    # Same irregular intervals as tb.v T4 — two groups of 16 alternating beats
    intervals = [
        2500, 9500, 3000, 8800, 2200, 9200, 3500, 8000,
        2800, 9800, 2000,10000, 3200, 8500, 2600, 9100,
        3100, 8200, 2400, 9600, 2700, 9300, 3300, 8700,
        2100, 9700, 3400, 8100, 2900, 9400,
    ]
    for ticks in intervals:
        await send_beat_after(dut, ticks)

    await ClockCycles(dut.clk, 100)

    afib = afib_flag(dut)
    spk  = any_spike(dut)
    conf = confidence(dut)
    valid = out_valid(dut)

    dut._log.info(f"T4: afib={afib} valid={valid} confidence={bin(conf)} any_spike={spk}")

    assert afib == 1, "T4a FAIL: AFib not detected on sustained irregular rhythm"
    dut._log.info("T4a PASS: AFib detected by 2-of-3 window majority (afib=1)")

    assert spk == 1, "T4b FAIL: No reservoir spikes seen during AFib sequence"
    dut._log.info("T4b PASS: Reservoir neurons fired during AFib sequence")


@cocotb.test()
async def test_t5_confidence_in_afib_range(dut):
    """
    T5: After AFib detection, confidence_latch should be >= 5 (3'b101).
    Runs immediately after T4 scenario (reset + reload + same intervals).
    """
    dut._log.info("T5: Confidence level check during AFib")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await do_reset_and_load(dut)

    intervals = [
        2500, 9500, 3000, 8800, 2200, 9200, 3500, 8000,
        2800, 9800, 2000,10000, 3200, 8500, 2600, 9100,
        3100, 8200, 2400, 9600, 2700, 9300, 3300, 8700,
        2100, 9700, 3400, 8100, 2900, 9400,
    ]
    for ticks in intervals:
        await send_beat_after(dut, ticks)

    await ClockCycles(dut.clk, 100)
    conf = confidence(dut)

    assert conf >= 0b101, \
        f"T5 FAIL: confidence_latch={bin(conf)} — expected >= 101 (AFib range)"
    dut._log.info(f"T5 PASS: confidence_latch={bin(conf)} is in AFib range (>= 101)")


@cocotb.test()
async def test_t6_asystole_detection(dut):
    """
    T6: After >16384 ticks (~1.6s at 10MHz) of silence, asystole_flag must assert.
    Then send an R-peak — flag must clear within 3 clocks.
    """
    dut._log.info("T6: Asystole detection — 17000-tick silence")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    model = AfibDetectorModel()
    await do_reset_and_load(dut)
    model.load_weights()

    await ClockCycles(dut.clk, 17000)
    model.tick(17000)

    asys = asystole_flag(dut)
    assert asys == 1, "T6a FAIL: Asystole flag did not assert after >16384 tick silence"
    dut._log.info("T6a PASS: Asystole flag asserted after >16384-tick silence (>1.6384s)")

    await send_r_peak(dut)
    model.r_peak()
    await ClockCycles(dut.clk, 3)

    asys = asystole_flag(dut)
    assert asys == 0, "T6b FAIL: Asystole flag did not clear after R-peak arrival"
    dut._log.info("T6b PASS: Asystole flag cleared on R-peak arrival")


@cocotb.test()
async def test_t7a_specificity_short_burst(dut):
    """
    T7a: Specificity — 4 irregular beats followed by 12 normal beats.
    Ultra window fires internally at beat 4, but 2-of-3 cannot be satisfied
    because fast and slow windows see predominantly normal rhythm.
    Expected: afib=0 (no false positive).
    """
    dut._log.info("T7a: Specificity — 4 irregular + 12 normal beats")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await do_reset_and_load(dut)

    # 4 irregular beats
    for ticks in [1500, 11000, 1800, 10500]:
        await send_beat_after(dut, ticks)

    # 12 normal beats
    for _ in range(12):
        await send_beat_after(dut, 7000)

    await ClockCycles(dut.clk, 100)

    afib = afib_flag(dut)
    conf = confidence(dut)
    dut._log.info(f"T7a: afib={afib} confidence={bin(conf)}")

    assert afib == 0, \
        "T7a FAIL: False positive — 4-beat burst incorrectly flagged as AFib"
    dut._log.info("T7a PASS: Specificity preserved — 4-beat burst not flagged (afib=0)")
    dut._log.info("       [Ultra window fired at beat 4, but 2-of-3 requires a second")
    dut._log.info("        window to agree; 12 normal beats prevent that]")


@cocotb.test()
async def test_t7b_ultra_window_sensitivity(dut):
    """
    T7b: Ultra-window sensitivity — 8 irregular beats then 8 normal.
    Ultra windows 1 AND 2 both flag. Fast window (beats 1-8) sees all irregular.
    Ultra + Fast = 2-of-3 satisfied → afib_flag=1.
    Expected: afib=1.
    """
    dut._log.info("T7b: Ultra sensitivity — 8 irregular + 8 normal beats")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    await do_reset_and_load(dut)

    # 8 irregular beats (4 alternating short/long pairs)
    for ticks in [1500, 11000, 1800, 10500, 2000, 10000, 1700, 11500]:
        await send_beat_after(dut, ticks)

    # 8 normal beats
    for _ in range(8):
        await send_beat_after(dut, 7000)

    await ClockCycles(dut.clk, 100)

    afib = afib_flag(dut)
    conf = confidence(dut)
    dut._log.info(f"T7b: afib={afib} confidence={bin(conf)}")

    assert afib == 1, \
        "T7b FAIL: 8-beat sustained AFib episode not detected"
    dut._log.info("T7b PASS: Ultra+Fast window pair detected 8-beat AFib episode (afib=1)")
    dut._log.info("       [Demonstrates ultra window provides real 2-of-3 contribution]")


@cocotb.test()
async def test_t8_reset_clears_all_state(dut):
    """
    T8: After full reset, afib_flag=0, out_valid=0, asystole=0, FSM=LOAD.
    """
    dut._log.info("T8: Reset clears all state")
    clock = Clock(dut.clk, CLK_PERIOD_NS, unit="ns")
    cocotb.start_soon(clock.start())

    # Run some beats first to dirty the state
    await do_reset_and_load(dut)
    for ticks in [2500, 9500, 3000, 8800]:
        await send_beat_after(dut, ticks)

    # Now reset
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)

    afib  = afib_flag(dut)
    valid = out_valid(dut)
    asys  = asystole_flag(dut)
    state = fsm_state(dut)

    assert afib  == 0,    f"T8 FAIL: afib_flag={afib} after reset"
    assert valid == 0,    f"T8 FAIL: out_valid={valid} after reset"
    assert asys  == 0,    f"T8 FAIL: asystole={asys} after reset"
    assert state == 0b00, f"T8 FAIL: FSM={bin(state)} after reset (expected LOAD=00)"

    dut._log.info("T8 PASS: Reset clears afib_flag, out_valid, asystole, FSM=LOAD")
    dut.rst_n.value = 1