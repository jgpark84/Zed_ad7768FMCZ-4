###############################################################################
## Copyright (C) 2019-2024 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

set_property  -dict {PACKAGE_PIN L18  IOSTANDARD LVCMOS25}  [get_ports clk_in]              ; ## H04  FMC_LPC_CLK0_M2C_P IO_L12P_T1_MRCC_34
set_property  -dict {PACKAGE_PIN M19  IOSTANDARD LVCMOS25}  [get_ports ready_in]            ; ## G06  FMC_LPC_LA00_CC_P  IO_L13P_T2_MRCC_34
set_property  -dict {PACKAGE_PIN M20  IOSTANDARD LVCMOS25}  [get_ports data_in[0]]          ; ## G07  FMC_LPC_LA00_CC_N  IO_L13N_T2_MRCC_34
set_property  -dict {PACKAGE_PIN L22  IOSTANDARD LVCMOS25}  [get_ports data_in[1]]          ; ## C11  FMC_LPC_LA06_N     IO_L10N_T1_34
set_property  -dict {PACKAGE_PIN P17  IOSTANDARD LVCMOS25}  [get_ports data_in[2]]          ; ## H07  FMC_LPC_LA02_P     IO_L20P_T3_34
set_property  -dict {PACKAGE_PIN P18  IOSTANDARD LVCMOS25}  [get_ports data_in[3]]          ; ## H08  FMC_LPC_LA02_N     IO_L20N_T3_34
set_property  -dict {PACKAGE_PIN J21  IOSTANDARD LVCMOS25}  [get_ports data_in[4]]          ; ## G12  FMC_LPC_LA08_P     IO_L8P_T1_34
set_property  -dict {PACKAGE_PIN J22  IOSTANDARD LVCMOS25}  [get_ports data_in[5]]          ; ## G13  FMC_LPC_LA08_N     IO_L8N_T1_34
set_property  -dict {PACKAGE_PIN R20  IOSTANDARD LVCMOS25}  [get_ports data_in[6]]          ; ## D14  FMC_LPC_LA09_P     IO_L17P_T2_34
set_property  -dict {PACKAGE_PIN R21  IOSTANDARD LVCMOS25}  [get_ports data_in[7]]          ; ## D15  FMC_LPC_LA09_N     IO_L17N_T2_34
set_property  -dict {PACKAGE_PIN J18  IOSTANDARD LVCMOS25}  [get_ports spi_csn]             ; ## D11  FMC_LPC_LA05_P     IO_L7P_T1_34
set_property  -dict {PACKAGE_PIN N19  IOSTANDARD LVCMOS25}  [get_ports spi_clk]             ; ## D08  FMC_LPC_LA01_CC_P  IO_L14P_T2_SRCC_34
set_property  -dict {PACKAGE_PIN M22  IOSTANDARD LVCMOS25}  [get_ports spi_mosi]            ; ## H11  FMC_LPC_LA04_N     IO_L15N_T2_DQS_34
set_property  -dict {PACKAGE_PIN N22  IOSTANDARD LVCMOS25}  [get_ports spi_miso]            ; ## G09  FMC_LPC_LA03_P     IO_L16P_T2_34
set_property  -dict {PACKAGE_PIN T19  IOSTANDARD LVCMOS25}  [get_ports gpio_0_mode_0]       ; ## C15  FMC_LPC_LA10_N     IO_L22N_T3_34
set_property  -dict {PACKAGE_PIN T16  IOSTANDARD LVCMOS25}  [get_ports gpio_1_mode_1]       ; ## H13  FMC_LPC_LA07_P     IO_L21P_T3_DQS_34
set_property  -dict {PACKAGE_PIN T17  IOSTANDARD LVCMOS25}  [get_ports gpio_2_mode_2]       ; ## H14  FMC_LPC_LA07_N     IO_L21N_T3_DQS_34
set_property  -dict {PACKAGE_PIN N17  IOSTANDARD LVCMOS25}  [get_ports gpio_3_mode_3]       ; ## H16  FMC_LPC_LA11_P     IO_L5P_T0_34
set_property  -dict {PACKAGE_PIN R19  IOSTANDARD LVCMOS25}  [get_ports gpio_4_filter]       ; ## C14  FMC_LPC_LA10_P     IO_L22P_T3_34
set_property  -dict {PACKAGE_PIN L21  IOSTANDARD LVCMOS25}  [get_ports reset_n]             ; ## C10  FMC_LPC_LA06_P     IO_L10P_T1_34
set_property  -dict {PACKAGE_PIN P22  IOSTANDARD LVCMOS25}  [get_ports start_n]             ; ## G10  FMC_LPC_LA03_N     IO_L16N_T2_34
set_property  -dict {PACKAGE_PIN N20  IOSTANDARD LVCMOS25}  [get_ports mclk]                ; ## D09  FMC_LPC_LA01_CC_N  IO_L14N_T2_SRCC_34

create_clock -name adc_clk -period 20 [get_ports clk_in]

# Physical Pmod DA3 mapping
# Signal order for each 6-pin DA3: SYNC, SDIN, LDAC, SCLK
# AO0 -> JA upper row (pins 1-4)
set_property -dict {PACKAGE_PIN Y11  IOSTANDARD LVCMOS33} [get_ports da3_sync]
set_property -dict {PACKAGE_PIN AA11 IOSTANDARD LVCMOS33} [get_ports da3_sdin]
set_property -dict {PACKAGE_PIN Y10  IOSTANDARD LVCMOS33} [get_ports da3_ldac]
set_property -dict {PACKAGE_PIN AA9  IOSTANDARD LVCMOS33} [get_ports da3_sclk]

# AO1 -> JA lower row (pins 7-10)
set_property -dict {PACKAGE_PIN AB11 IOSTANDARD LVCMOS33} [get_ports da3_1_sync]
set_property -dict {PACKAGE_PIN AB10 IOSTANDARD LVCMOS33} [get_ports da3_1_sdin]
set_property -dict {PACKAGE_PIN AB9  IOSTANDARD LVCMOS33} [get_ports da3_1_ldac]
set_property -dict {PACKAGE_PIN AA8  IOSTANDARD LVCMOS33} [get_ports da3_1_sclk]

# AO2 -> JB upper row (pins 1-4)
set_property -dict {PACKAGE_PIN W12 IOSTANDARD LVCMOS33} [get_ports da3_2_sync]
set_property -dict {PACKAGE_PIN W11 IOSTANDARD LVCMOS33} [get_ports da3_2_sdin]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports da3_2_ldac]
set_property -dict {PACKAGE_PIN W8  IOSTANDARD LVCMOS33} [get_ports da3_2_sclk]

# AO3 -> JB lower row (pins 7-10)
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports da3_3_sync]
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS33} [get_ports da3_3_sdin]
set_property -dict {PACKAGE_PIN V9  IOSTANDARD LVCMOS33} [get_ports da3_3_ldac]
set_property -dict {PACKAGE_PIN V8  IOSTANDARD LVCMOS33} [get_ports da3_3_sclk]


# =============================================================================
# CN0531 / AD5791: two independent 20-bit DAC outputs on JC (AO4) / JD (AO5)
# ZedBoard JC/JD PACKAGE_PIN values: ZedBoard Hardware User Guide, Table 16.
# Each JC/JD pin is used as single-ended 3.3 V GPIO (LVCMOS33).
#
# CN0531 P2 connector mapping confirmed from ADI CN0531 schematic,
# sheet 2 (drawing 02_058962, rev B):
#   Pmod 1 = /SYNC, 2 = SDIN, 3 = SDO (unused), 4 = SCLK,
#   Pmod 7 = /LDAC, 8 = /RESET, 9 = /CLR, 10 = unconnected.
#   Pmod 5/11 = GND; 6/12 = 3.3 V.
# =============================================================================

# AO4 -> JC
set_property -dict {PACKAGE_PIN AB7 IOSTANDARD LVCMOS33} [get_ports cn0531_jc_sync_n]   ; # JC1  /SYNC
set_property -dict {PACKAGE_PIN AB6 IOSTANDARD LVCMOS33} [get_ports cn0531_jc_sdin]     ; # JC2  SDIN
set_property -dict {PACKAGE_PIN AA4 IOSTANDARD LVCMOS33} [get_ports cn0531_jc_sclk]     ; # JC4  SCLK
set_property -dict {PACKAGE_PIN R6  IOSTANDARD LVCMOS33} [get_ports cn0531_jc_ldac_n]   ; # JC7  /LDAC
set_property -dict {PACKAGE_PIN T6  IOSTANDARD LVCMOS33} [get_ports cn0531_jc_reset_n]  ; # JC8  /RESET
set_property -dict {PACKAGE_PIN T4  IOSTANDARD LVCMOS33} [get_ports cn0531_jc_clr_n]    ; # JC9  /CLR

# AO5 -> JD
set_property -dict {PACKAGE_PIN V7  IOSTANDARD LVCMOS33} [get_ports cn0531_jd_sync_n]   ; # JD1  /SYNC
set_property -dict {PACKAGE_PIN W7  IOSTANDARD LVCMOS33} [get_ports cn0531_jd_sdin]     ; # JD2  SDIN
set_property -dict {PACKAGE_PIN V4  IOSTANDARD LVCMOS33} [get_ports cn0531_jd_sclk]     ; # JD4  SCLK
set_property -dict {PACKAGE_PIN W6  IOSTANDARD LVCMOS33} [get_ports cn0531_jd_ldac_n]   ; # JD7  /LDAC
set_property -dict {PACKAGE_PIN W5  IOSTANDARD LVCMOS33} [get_ports cn0531_jd_reset_n]  ; # JD8  /RESET
set_property -dict {PACKAGE_PIN U6  IOSTANDARD LVCMOS33} [get_ports cn0531_jd_clr_n]    ; # JD9  /CLR
