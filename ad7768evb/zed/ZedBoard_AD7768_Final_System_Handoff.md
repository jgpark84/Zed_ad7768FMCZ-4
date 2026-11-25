# ZedBoard + EVAL-AD7768-4FMCZ Real-Time Control Platform
## AI / Maintainer Handoff Summary

**Status:** Final known timing-clean build baseline  
**Target board:** ZedBoard (XC7Z020-1CLG484C)  
**ADC board:** Analog Devices EVAL-AD7768-4FMCZ  
**HDL tree:** ADI HDL `hdl_2023_r2`  
**Vivado:** 2025.2  
**Project:** `/mnt/c/hdl_clean/projects/ad7768evb/zed`

---

# 1. Purpose

This project extends the Analog Devices EVAL-AD7768-4FMCZ ZedBoard reference design into a real-time FPGA control platform.

The architecture deliberately separates:

1. **Raw ADC acquisition / storage**
   - Existing ADI ADC -> DMA -> Linux IIO path
   - Must remain as intact as possible
2. **Real-time control**
   - Runs entirely in PL
   - Averaging -> CORDIC / normalization -> PID -> AO
3. **Low-rate configuration and readback**
   - AXI-Lite / MMIO
   - Linux/PS is not part of the deterministic control loop
4. **Physical analog output**
   - Four logical AO channels
   - Two Pmod DA3 outputs on JA
   - Two Pmod DA3 outputs on JB

Future planned extension:
- Continuous AO telemetry should use a **separate streaming DMA path**
- Existing AD7768 DMA/IIO raw acquisition should remain unchanged

---

# 2. Final Known Good Build

The latest confirmed build is the version after:

- 4 physical AO channels were added
- JA and JB Pmod outputs were wired
- temporary LED clock-debug counters were removed
- APPLY and SNAPSHOT command addresses were separated

Final bitstream:

```text
/mnt/c/hdl_clean/projects/ad7768evb/zed/
  ad7768evb_zed.runs/impl_1/system_top.bit
```

Final timing result:

```text
WNS = +0.278 ns
TNS = 0
Failing endpoints = 0

All user specified timing constraints are met.
```

Important clock-domain results:

```text
adc_clk      WNS = +3.522 ns
clk_fpga_0   WNS = +0.833 ns
mmcm_clk_0_s WNS = +0.278 ns

clk_fpga_0 -> adc_clk : +5.607 ns
adc_clk    -> clk_fpga_0 : +5.007 ns
```

This is the current baseline. Any future modification should preserve timing closure.

---

# 3. Overall System Architecture

```text
                    +-----------------------------+
                    |       EVAL-AD7768-4FMCZ     |
                    |       4-channel ADC         |
                    +-------------+---------------+
                                  |
                                  v
                    +-----------------------------+
                    |   ADI axi_ad7768 interface  |
                    |   adc_data_0..3 / adc_valid |
                    +-------------+---------------+
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
      +----------------------+          +--------------------------+
      | Existing ADI raw path|          | Custom real-time path    |
      | ADC -> ADI DMA       |          | avg4ch_prog              |
      | -> DDR -> IIO/Linux  |          | -> CORDIC / normalizer   |
      +----------------------+          | -> PID -> AO scaler      |
                                        +------------+-------------+
                                                     |
                                                     v
                                            +----------------+
                                            | AO0..AO3       |
                                            | final 16-bit   |
                                            +--+--+--+--+----+
                                               |  |  |  |
                                               v  v  v  v
                                        Pmod DA3 physical outputs
```

---

# 4. Clock Domains

## 4.1 `adc_clk`

- Derived directly from physical `clk_in`
- Verified in `axi_ad7768_if.v`
- `adc_clk = clk_in`
- Current timing report shows a 20 ns period, i.e. 50 MHz clock
- Real-time signal-processing logic lives primarily here

Used by:
- averaging
- CORDIC
- input normalizer
- PID cores
- AO scalers
- real-time configuration local bank
- snapshot/live state capture

## 4.2 `clk_fpga_0`

- PS FCLK
- AXI-Lite `app_ctrl` register block runs here
- Current report shows 10 ns period, i.e. 100 MHz

Used by:
- AXI-Lite register interface
- software-visible shadow registers
- readback bank
- Pmod DA3 SPI drivers in the current design

---

# 5. ADC Data Format

The AD7768 ADC word is:

```text
[31:24] = status / CRC-related field
[23:0]  = signed 24-bit ADC sample
```

For control logic, use only the signed 24-bit sample:

```verilog
{{8{adc_data_0[23]}}, adc_data_0[23:0]}
```

Do **not** interpret the full 32-bit ADC word as a signed sample.

---

# 6. Averaging

Module:

```text
avg4ch_prog.v
```

Properties:
- 4 channels
- signed 32-bit I/O
- 40-bit signed accumulators
- max averaging length: 1024 samples
- runtime programmable

```text
N = 2^avg_shift
avg_shift = 0..10
```

`avg_valid` is asserted once per completed averaging window and is the natural control-loop tick.

Nominal ADC sample rate discussed for the system:

```text
256 kS/s per channel
```

Therefore:

```text
loop_rate = ADC_sample_rate / 2^avg_shift
```

Examples:

```text
avg_shift = 0  -> 256 kHz
avg_shift = 4  -> 16 kHz
avg_shift = 8  -> 1 kHz
avg_shift = 10 -> 250 Hz
```

---

# 7. CORDIC

Module:

```text
cordic_atan2.v
```

Three logical CORDIC paths:

```text
CORDIC0 : averaged-data phase path
CORDIC1 : averaged-data phase path
CORDIC2 : raw ADC phase-monitor path
```

Each CORDIC has independent X/Y source selectors.

Important:
- CORDIC0/1 receive `avg_valid`
- CORDIC2 receives raw `adc_valid`
- CORDIC is iterative (~31 iterations)
- if CORDIC2 is busy, raw input samples may be missed
- a future miss counter such as `in_valid && busy` is desirable

Phase representation:

```text
signed 32-bit BAM, full turn = 2^32

0x00000000 = 0
0x40000000 = +pi/2
0x80000000 = pi boundary / -pi
0xC0000000 = -pi/2
```

---

# 8. Input Normalizer

Module:

```text
input_normalizer.v
```

General ADC PID path:

```text
ADC avg source
 -> input_normalizer
 -> normalized signed32
 -> PID2 / PID3
```

Phase PID path:

```text
I/Q
 -> CORDIC
 -> signed32 phase
 -> PID0 / PID1
```

The normalizer computes only:

```text
(source_data - center_reg) * scale_reg
```

followed by fixed-point alignment and signed-32 saturation.

Critical invariant:

> The normalizer does **not** calculate center or scale coefficients itself.

Software calculates center/scale and writes them through AXI-Lite.

Scale format:

```text
Q16.16

0x00010000 = 1.0
0x00008000 = 0.5
0x00020000 = 2.0
```

For simple 24-bit-to-signed32 expansion, factor 256 is:

```text
0x01000000
```

---

# 9. PID Architecture

Module:

```text
pid_core.v
```

Four PIDs:

```text
PID0 : phase PID
PID1 : phase PID
PID2 : general ADC PID
PID3 : general ADC PID
```

Sources:

```text
PID0/1:
  select CORDIC0 / CORDIC1 / CORDIC2

PID2/3:
  select averaged ADC input
  -> input_normalizer
  -> PID
```

Common PID input representation:

```text
signed 32-bit
```

General PID error:

```text
error = setpoint - input
```

Phase PID uses modular 32-bit phase difference.

PID coefficient format:

```text
Q16.16
```

The PID is pipelined. A previous monolithic implementation caused roughly:

```text
~37.9 ns data path
WNS ~ -18 ns
```

The pipelined implementation solved this timing problem.

`pid_core.v` no longer performs input center/scale normalization.

---

# 10. AO Architecture

Four logical AO channels:

```text
AO0
AO1
AO2
AO3
```

Each AO supports:
- source selector
- manual code
- gain
- offset
- min
- max
- output readback
- status

Source selector:

```text
0 = manual
1 = PID0
2 = PID1
3 = PID2
4 = PID3
```

Conceptual scaling:

```text
scaled = (source_data * gain >> 16) + offset
```

Then clamp to:
1. user min/max
2. physical DAC range 0..65535

AO gain format:

```text
Q16.16
```

Examples:

```text
0x00010000 = gain 1.0
```

For mapping signed32 phase-scale PID output into about +/-32768 DAC counts around midscale:

```text
gain   = 0x00000001
offset = 0x00008000
```

---

# 11. Physical Pmod DA3 Mapping

Current physical mapping:

```text
AO0 -> JA upper
AO1 -> JA lower
AO2 -> JB upper
AO3 -> JB lower
```

## AO0 / JA upper

```text
JA1  Y11  SYNC / CS
JA2  AA11 DIN
JA3  Y10  LDAC
JA4  AA9  SCLK
```

## AO1 / JA lower

```text
JA7  AB11 SYNC / CS
JA8  AB10 DIN
JA9  AB9  LDAC
JA10 AA8  SCLK
```

## AO2 / JB upper

```text
JB1  W12  SYNC / CS
JB2  W11  DIN
JB3  V10  LDAC
JB4  W8   SCLK
```

## AO3 / JB lower

```text
JB7  V12  SYNC / CS
JB8  W10  DIN
JB9  V9   LDAC
JB10 V8   SCLK
```

Each logical AO feeds a separate `da3_driver.v` instance.

Conceptual path:

```text
PID / manual
 -> AO scaler
 -> final 16-bit DAC code
 -> da3_driver.v
 -> Pmod DA3
 -> analog output
```

---

# 12. AXI-Lite Control Interface

Module family:

```text
app_ctrl.v
app_ctrl_reg.v
up_axi.v
```

`app_ctrl` is plain RTL/module-reference logic, not a separately packaged custom IP.

Base address:

```text
0x43C10000
```

AXI address width:

```text
9 bits
```

Address range:

```text
0x000 .. 0x1FF
```

Example Linux access:

```bash
busybox devmem 0x43C10000 32
```

---

# 13. Register Map

Base:

```text
BASE = 0x43C10000
```

## Common / CORDIC

```text
0x000 legacy/manual dac_code alias AO0 manual
0x004 avg0 RO
0x008 avg1 RO
0x00C avg2 RO
0x010 avg3 RO

0x014 avg_shift RW shadow

0x018 cordic0_sel_x RW shadow
0x01C cordic0_sel_y RW shadow
0x020 cordic1_sel_x RW shadow
0x024 cordic1_sel_y RW shadow
0x028 cordic2_sel_x RW shadow
0x02C cordic2_sel_y RW shadow

0x030 cordic0_phase RO
0x034 cordic1_phase RO
0x038 cordic2_phase RO
0x03C cordic_status RO
```

## PID blocks

Bases:

```text
PID0 = 0x040
PID1 = 0x080
PID2 = 0x0C0
PID3 = 0x100
```

Offsets:

```text
+00 control
    bit0 enable shadow
    bit1 RESET command

+04 input_sel
+08 center
+0C scale Q16.16
+10 setpoint
+14 kp Q16.16
+18 ki Q16.16
+1C kd Q16.16
+20 out_min
+24 out_max
+28 output RO
+2C error RO
+30 integrator RO
+34 status RO
```

Notes:
- PID0/1 center/scale addresses are retained for compatibility
- PID0/1 phase datapath does not use center/scale
- PID2/3 use center/scale through `input_normalizer.v`

## AO blocks

Bases:

```text
AO0 = 0x140
AO1 = 0x160
AO2 = 0x180
AO3 = 0x1A0
```

Offsets:

```text
+00 source_sel
+04 manual_code
+08 gain Q16.16
+0C offset
+10 out_min
+14 out_max
+18 output RO
+1C status RO
```

## Command / CDC addresses

Final split-command map:

```text
0x1C0 APPLY_CMD
0x1C4 SNAPSHOT_CMD
0x1C8 APPLY_SEQ RO
0x1CC SNAPSHOT_SEQ RO
```

Current semantics:

```text
write 1 to 0x1C0 -> APPLY event
write 1 to 0x1C4 -> SNAPSHOT event
```

---

# 14. Current CDC Architecture

## Configuration direction

```text
AXI shadow registers
(clk_fpga_0)
      |
      | APPLY event
      v
toggle CDC
      |
      v
adc_clk local configuration bank
      |
      v
real-time logic
```

APPLY captures persistent configuration including:
- avg_shift
- CORDIC selectors
- PID enable/select/center/scale/setpoint/Kp/Ki/Kd/min/max
- AO source/manual/gain/offset/min/max

Important:

```text
APPLY != RESET
```

APPLY updates configuration only.

## PID reset

Each PID control register bit1 generates a reset toggle. The reset crosses into `adc_clk` using:

```text
2FF synchronizer
+ delayed copy
+ XOR edge detect
```

Useful one-write regression test:

```bash
busybox devmem 0x43C10040 32 0x00000002
busybox devmem 0x43C10070 32
```

Integrator should read zero after a single reset write.

## Readback / snapshot direction

Current implemented structure:

```text
adc_clk live state
      |
      | SNAPSHOT command
      v
adc_clk snapshot bank
      |
      v
CDC transfer
      |
      v
AXI-domain readback bank
      |
      v
software
```

This provides coherent readback across multiple registers.

---

# 15. Planned Readback Simplification

A newer architectural decision is being considered:

> Remove software-triggered SNAPSHOT and update the readback snapshot automatically on every control-loop update.

Natural trigger:

```text
avg_valid
```

Proposed structure:

```text
avg_valid
 -> adc_clk snapshot bank update
 -> AXI-domain latest-state readback bank
 -> software reads whenever needed
```

Potential benefits:
- remove `SNAPSHOT_CMD`
- remove snapshot-command toggle CDC
- remove snapshot edge detector
- reduce event/control logic
- software no longer needs "snapshot then read"

Important:
- the readback data CDC still exists
- only the event-driven snapshot-command CDC would disappear

This change is **not yet part of the final known-good bitstream**.

---

# 16. Existing ADI Raw DMA / IIO Path

The original ADI acquisition path remains active and should not be modified unnecessarily.

Conceptually:

```text
AD7768
 -> ADI ADC interface
 -> ADI DMA
 -> PS DDR
 -> Linux IIO
 -> userspace / libiio
```

Purpose:
- full raw ADC acquisition
- raw binary storage
- continuous data stream

Planned software behavior:

```text
IIO/DMA stream is continuously consumed.

if recording:
    write received raw blocks to file
else:
    discard after monitoring/processing
```

This avoids repeatedly starting/stopping the existing ADI acquisition pipeline.

---

# 17. Planned AO Streaming DMA

Continuous AO history must eventually be recorded without missing control-loop samples.

AXI-Lite MMIO remains suitable for:
- configuration
- status
- latest-value monitoring

It is not the preferred path for lossless AO waveform capture.

Planned architecture:

```text
final AO0..AO3 16-bit codes
        |
        | pack once per control-loop update
        v
64-bit AO frame
        |
        v
AXI-Stream formatter
        |
        v
AXI-Stream FIFO
        |
        v
additional DMA instance
        |
        v
PS DDR
        |
        v
Linux/userspace
```

Minimal frame:

```text
[AO3 16b][AO2 16b][AO1 16b][AO0 16b]
```

Current preference:
- first implementation should be AO-only
- do not unnecessarily add avg/PID/phase fields
- minimize Linux and HDL changes

Optional future fields:
- sequence number
- timestamp
- PID output
- averaged ADC values

---

# 18. DMA Design Philosophy

Do **not** design a custom DMA engine from scratch.

Preferred strategy:

```text
custom AO AXI-Stream source
 -> existing/vendor DMA IP
 -> existing Linux DMA infrastructure
```

Possible candidate:
- ADI AXI DMAC, because the current platform is already ADI-based

Goal: avoid implementing custom:
- DDR bus-master logic
- descriptor engine
- memory allocator
- ring-buffer infrastructure
- cache-coherency mechanism

Linux should continue to own/manage DMA-safe buffers.

---

# 19. DMA Resource / Conflict Considerations

Before adding a new DMA instance, inspect the existing design.

Check:
1. which PS HP port the existing ADI DMA uses
2. whether unused HP ports are available
3. current PL resource utilization
4. DMA MMIO base addresses
5. IRQ assignments
6. device-tree DMA phandles
7. Linux/IIO buffer ownership
8. interconnect / clock converter / FIFO structure

Important conceptual distinction:
- Zynq PS has an internal DMAC with its own channel limits
- an added PL AXI DMAC instance is a separate concept

Practical limits for another PL DMA are:
- LUT / FF / BRAM
- AXI interconnect
- HP port connectivity
- IRQs
- memory bandwidth
- software/device-tree setup

Expected AO data rate is small.

Examples:

```text
4 ch * 16 bit * 16 kHz  = ~128 kB/s
4 ch * 16 bit * 256 kHz = ~2 MB/s
```

Therefore DDR bandwidth itself is unlikely to be the main problem.

---

# 20. Timing / Implementation Lessons

Do not optimize blindly.

## BRAM replacement for wide config/readback banks

Not currently attractive because:
- config values are consumed in parallel
- snapshot semantics require simultaneous capture
- BRAM is address-oriented
- BRAM would likely need to be unpacked into registers again
- current timing is already clean

## Explicit DSP48 coding

Vivado already infers DSP48 blocks for relevant multiplication paths.

Only rewrite around strict DSP48 templates if:
- utilization becomes a real problem
- timing reports identify arithmetic as the real critical path

---

# 21. Build / Boot Notes

Clean HDL tree:

```text
Windows:
C:\hdl_clean

WSL:
/mnt/c/hdl_clean
```

Branch:

```text
hdl_2023_r2
```

Project:

```text
/mnt/c/hdl_clean/projects/ad7768evb/zed
```

Bitstream:

```text
/mnt/c/hdl_clean/projects/ad7768evb/zed/
  ad7768evb_zed.runs/impl_1/system_top.bit
```

Boot staging:

```text
/mnt/c/hdl_clean/boot_test
```

BOOT.BIN generation:

```bash
bootgen -image zynq.bif -arch zynq -o BOOT.BIN -w
```

Typical BIF contains:
- FSBL
- FPGA bitstream
- U-Boot

Board SSH:

```text
root@169.254.92.202
```

Boot partition:

```text
/boot
```

Avoid backup filenames containing spaces such as:

```text
system_top - 복사본.v
```

The ADI Makefile wildcard behavior previously caused build problems with such filenames.

---

# 22. Important Source Files

Custom / modified files include:

```text
system_top.v
system_bd.tcl
system_constr.xdc

app_ctrl.v
app_ctrl_reg.v

avg4ch_prog.v
cordic_atan2.v
input_normalizer.v
pid_core.v
ao_scaler.v
da3_driver.v
```

Relevant ADI source:

```text
axi_ad7768.v
axi_ad7768_if.v
```

Verified fact:

```text
adc_clk = clk_in
```

---

# 23. AI / Maintainer Invariants

Treat these as design constraints unless intentionally changing the architecture.

1. **Do not modify the existing ADI raw DMA/IIO path unnecessarily.**
2. **ADC sample is signed 24-bit in `[23:0]`; the upper byte is not sample data.**
3. **PID input representation is common signed32.**
4. **Phase path:** `CORDIC -> PID0/PID1`; no normalizer.
5. **General ADC path:** `ADC average -> input_normalizer -> PID2/PID3`.
6. **Normalizer does not estimate center/scale; software does.**
7. **APPLY is configuration commit only; it does not reset PID state.**
8. **RESET is independent from APPLY.**
9. **Current final build still has software-triggered SNAPSHOT.**
10. **Auto-snapshot on `avg_valid` is a proposed next simplification, not yet the baseline.**
11. **Config path is AXI shadow -> APPLY -> adc_clk local bank.**
12. **Readback uses adc_clk state/snapshot -> AXI readback bank.**
13. **Explicit CDC treatment is required.**
14. **Do not alter the existing `gpio_i[32]` oddity without a proven reason; it was intentionally left untouched.**
15. **Preserve AO0..AO3 logical-to-Pmod mapping unless intentionally revising software/register documentation too.**
16. **Timing closure is mandatory. A generated bitstream with failed timing is not a valid baseline.**
17. **Do not re-open already disproven generic clock-failure hypotheses. FCLK, physical `clk_in`, and `adc_clk` were verified.**

---

# 24. Recommended Next Steps

1. Keep the current timing-clean bitstream as a checkpoint.
2. Decide whether to replace `SNAPSHOT_CMD` with automatic `avg_valid`-driven readback update.
3. If changed, rebuild and verify:
   - overall timing
   - adc_clk timing
   - inter-clock paths
   - coherent readback
4. For continuous AO recording:
   - inspect existing ADI DMA -> HP port / IRQ / DT topology
   - inspect current FPGA utilization
   - add AO AXI-Stream producer
   - add FIFO
   - add second vendor DMA instance
   - keep existing AD7768 DMA/IIO untouched
5. Linux goal for AO DMA:
   - reuse existing DMA infrastructure
   - avoid a custom DMA engine
   - expose a simple streaming userspace interface, preferably reusing IIO/libiio if practical

---

# 25. Mental Model

The platform has three planes:

```text
CONTROL PLANE
PS/Linux
 -> AXI-Lite
 -> shadow config
 -> APPLY
 -> real-time config

REAL-TIME PLANE
AD7768
 -> average
 -> CORDIC / normalization
 -> PID
 -> AO scaler
 -> Pmod DA3

DATA PLANE
A) ADC raw
AD7768
 -> existing ADI DMA/IIO

B) Future AO telemetry
final AO codes
 -> AXI-Stream
 -> separate DMA
 -> DDR
```

Central architectural principle:

> **Linux configures and observes. PL controls in real time. DMA moves continuous data.**
