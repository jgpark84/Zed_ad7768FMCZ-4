Changes in this package
=======================

1. Four physical Pmod DA3 outputs are mapped to the existing four logical AO channels:
   AO0 -> JA upper row: JA1 SYNC, JA2 SDIN, JA3 LDAC, JA4 SCLK
   AO1 -> JA lower row: JA7 SYNC, JA8 SDIN, JA9 LDAC, JA10 SCLK
   AO2 -> JB upper row: JB1 SYNC, JB2 SDIN, JB3 LDAC, JB4 SCLK
   AO3 -> JB lower row: JB7 SYNC, JB8 SDIN, JB9 LDAC, JB10 SCLK

2. Each AO uses its existing ao_output 16-bit lane:
   AO0 ao_output[15:0]
   AO1 ao_output[31:16]
   AO2 ao_output[47:32]
   AO3 ao_output[63:48]

3. The temporary clock-debug LED counters were removed.
   gpio_bd_o_mux and gpio_bd_t_mux are restored to the normal GPIO buses.

4. PID, normalizer, AXI register map, APPLY/SNAPSHOT CDC, and ADI DMA/IIO paths are unchanged.

5. The existing DA3 driver module is reused four times. No new DAC register addresses are needed;
   the logical AO0..AO3 register map already exists.

6. Note: The physical AO -> DA3 driver clock-domain crossing remains the same architectural issue
   already observed for AO0. This package does not alter that CDC; it only extends the same physical
   output scheme to AO1..AO3.

COMMAND REGISTER SPLIT UPDATE
-----------------------------
The APPLY and SNAPSHOT command addresses are now independent:
  0x1C0 APPLY_CMD      : write bit0=1 to trigger APPLY
  0x1C4 SNAPSHOT_CMD   : write bit0=1 to trigger SNAPSHOT
  0x1C8 APPLY_SEQ      : read-only sequence counter
  0x1CC SNAPSHOT_SEQ   : read-only sequence counter

The toggle-based CDC and the APPLY/SNAPSHOT behavior in system_top.v are unchanged.
Only the AXI-side command decode/readback addresses changed.
