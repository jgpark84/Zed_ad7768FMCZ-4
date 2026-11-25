Input-normalizer refactor
=========================

Architecture after this change
------------------------------
PID0/PID1:
  selected CORDIC phase -> signed32 -> pid_core

PID2/PID3:
  selected averaged ADC channel -> input_normalizer -> signed32 -> pid_core

input_normalizer realtime operation
-----------------------------------
  normalized = (source_data - center) * scale / 2^16

- center is a signed32 value in the selected source's native numeric domain.
- scale is signed Q16.16.
- center and scale are NOT calculated in PL. Software calculates them and writes
  them to the AXI registers; the realtime datapath treats them as constants.
- subtraction is 33-bit, multiplication is 65-bit, and the final output is
  saturated to signed32.
- input_normalizer has a valid pipeline; PID2/PID3 update from normalizer_valid.

PID core
--------
- input_offset/input_gain have been removed.
- pid_core assumes input_data is already signed32 in the PID input domain.
- phase-mode modular error and general-mode saturated subtraction are retained.
- the existing PID pipeline depth is retained to avoid re-opening the timing
  path that was already closed.

Register map compatibility
--------------------------
The byte addresses are unchanged:
  PID base + 0x08 : input center   (formerly input offset)
  PID base + 0x0C : input scale    (formerly input gain, still Q16.16)

PID2/PID3 use these registers in input_normalizer.
PID0/PID1 keep the read/write registers for address-map compatibility, but the
phase datapath ignores them because CORDIC already produces signed32 phase.

Default center = 0 and scale = 0x00010000 (1.0), preserving pass-through
behavior for the general inputs until software programs a normalization scale.

Files changed
-------------
  system_top.v
  pid_core.v
  app_ctrl.v
  app_ctrl_reg.v
  system_bd.tcl
  system_project.tcl

New file
--------
  input_normalizer.v
