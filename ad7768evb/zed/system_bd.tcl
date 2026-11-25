###############################################################################
## Copyright (C) 2014-2024 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

source $ad_hdl_dir/projects/common/zed/zed_system_bd.tcl
source $ad_hdl_dir/projects/scripts/adi_pd.tcl

# system ID
ad_ip_parameter axi_sysid_0 CONFIG.ROM_ADDR_BITS 9
ad_ip_parameter rom_sys_0 CONFIG.PATH_TO_FILE "$mem_init_sys_file_path/mem_init_sys.txt"
ad_ip_parameter rom_sys_0 CONFIG.ROM_ADDR_BITS 9

sysid_gen_sys_init_file

source ../common/ad7768evb_bd.tcl


###############################################################################
# Clocks / ADC data exported to system_top
###############################################################################

create_bd_port -dir O da3_clk
ad_connect sys_ps7/FCLK_CLK0 da3_clk

create_bd_port -dir O adc_test_clk
ad_connect axi_ad7768_adc/adc_clk adc_test_clk

create_bd_port -dir O adc_valid
ad_connect axi_ad7768_adc/adc_valid adc_valid

create_bd_port -dir O -from 31 -to 0 adc_data_0
create_bd_port -dir O -from 31 -to 0 adc_data_1
create_bd_port -dir O -from 31 -to 0 adc_data_2
create_bd_port -dir O -from 31 -to 0 adc_data_3

ad_connect axi_ad7768_adc/adc_data_0 adc_data_0
ad_connect axi_ad7768_adc/adc_data_1 adc_data_1
ad_connect axi_ad7768_adc/adc_data_2 adc_data_2
ad_connect axi_ad7768_adc/adc_data_3 adc_data_3


###############################################################################
# app_ctrl AXI-Lite module
###############################################################################

add_files -norecurse app_ctrl.v
add_files -norecurse app_ctrl_reg.v
add_files -norecurse control_stream_serializer.v
add_files -norecurse $ad_hdl_dir/library/common/up_axi.v

create_bd_cell -type module -reference app_ctrl app_ctrl_0
create_bd_cell -type module -reference control_stream_serializer control_stream_serializer_0

disconnect_bd_net \
  [get_bd_nets -of_objects [get_bd_pins ad7768_dma/fifo_wr_en]] \
  [get_bd_pins ad7768_dma/fifo_wr_en]

disconnect_bd_net \
  [get_bd_nets -of_objects [get_bd_pins ad7768_dma/fifo_wr_din]] \
  [get_bd_pins ad7768_dma/fifo_wr_din]

disconnect_bd_net \
  [get_bd_nets -of_objects [get_bd_pins ad7768_dma/fifo_wr_sync]] \
  [get_bd_pins ad7768_dma/fifo_wr_sync]

ad_connect control_stream_serializer_0/stream_valid ad7768_dma/fifo_wr_en
ad_connect control_stream_serializer_0/stream_data  ad7768_dma/fifo_wr_din
ad_connect control_stream_serializer_0/stream_sync  ad7768_dma/fifo_wr_sync

ad_connect axi_ad7768_adc/adc_clk control_stream_serializer_0/clk
ad_connect sys_ps7/FCLK_RESET0_N control_stream_serializer_0/resetn

ad_cpu_interconnect 0x43C10000 app_ctrl_0


###############################################################################
# Common
###############################################################################

create_bd_port -dir O -from 15 -to 0 dac_code
ad_connect app_ctrl_0/dac_code dac_code

create_bd_port -dir O -from 3 -to 0 avg_shift
ad_connect app_ctrl_0/avg_shift avg_shift

###############################################################################
# One-way APPLY command
###############################################################################

create_bd_port -dir O apply_toggle
ad_connect app_ctrl_0/apply_toggle apply_toggle


###############################################################################
# Live averaged ADC stream input
###############################################################################

create_bd_port -dir I phase_valid
ad_connect phase_valid control_stream_serializer_0/frame_valid

create_bd_port -dir I -from 31 -to 0 avg0
create_bd_port -dir I -from 31 -to 0 avg1
create_bd_port -dir I -from 31 -to 0 avg2
create_bd_port -dir I -from 31 -to 0 avg3


ad_connect avg0 control_stream_serializer_0/avg0
ad_connect avg1 control_stream_serializer_0/avg1
ad_connect avg2 control_stream_serializer_0/avg2
ad_connect avg3 control_stream_serializer_0/avg3

# Wrapped phase stream: CORDIC0 and CORDIC1, signed32 BAM
create_bd_port -dir I -from 63 -to 0 cordic_phase
ad_connect cordic_phase control_stream_serializer_0/cordic_phase

###############################################################################
# CORDIC packed configuration
###############################################################################

create_bd_port -dir O -from 5 -to 0 cordic_sel_x
create_bd_port -dir O -from 5 -to 0 cordic_sel_y

ad_connect app_ctrl_0/cordic_sel_x cordic_sel_x
ad_connect app_ctrl_0/cordic_sel_y cordic_sel_y



###############################################################################
# PID packed configuration
###############################################################################

create_bd_port -dir O -from 3 -to 0 pid_enable
create_bd_port -dir O -from 3 -to 0 pid_reset_toggle

create_bd_port -dir O -from 7 -to 0 pid_input_sel

create_bd_port -dir O -from 127 -to 0 pid_input_center
create_bd_port -dir O -from 127 -to 0 pid_input_scale
create_bd_port -dir O -from 127 -to 0 pid_setpoint

create_bd_port -dir O -from 127 -to 0 pid_kp
create_bd_port -dir O -from 127 -to 0 pid_ki
create_bd_port -dir O -from 127 -to 0 pid_kd

create_bd_port -dir O -from 127 -to 0 pid_out_min
create_bd_port -dir O -from 127 -to 0 pid_out_max

ad_connect app_ctrl_0/pid_enable pid_enable
ad_connect app_ctrl_0/pid_reset_toggle pid_reset_toggle

ad_connect app_ctrl_0/pid_input_sel pid_input_sel

ad_connect app_ctrl_0/pid_input_center pid_input_center
ad_connect app_ctrl_0/pid_input_scale pid_input_scale
ad_connect app_ctrl_0/pid_setpoint pid_setpoint

ad_connect app_ctrl_0/pid_kp pid_kp
ad_connect app_ctrl_0/pid_ki pid_ki
ad_connect app_ctrl_0/pid_kd pid_kd

ad_connect app_ctrl_0/pid_out_min pid_out_min
ad_connect app_ctrl_0/pid_out_max pid_out_max



###############################################################################
# AO packed configuration
###############################################################################

create_bd_port -dir O -from 11 -to 0 ao_source_sel
create_bd_port -dir O -from 63 -to 0 ao_manual_code

create_bd_port -dir O -from 127 -to 0 ao_gain
create_bd_port -dir O -from 127 -to 0 ao_offset
create_bd_port -dir O -from 127 -to 0 ao_out_min
create_bd_port -dir O -from 127 -to 0 ao_out_max

ad_connect app_ctrl_0/ao_source_sel ao_source_sel
ad_connect app_ctrl_0/ao_manual_code ao_manual_code

ad_connect app_ctrl_0/ao_gain ao_gain
ad_connect app_ctrl_0/ao_offset ao_offset
ad_connect app_ctrl_0/ao_out_min ao_out_min
ad_connect app_ctrl_0/ao_out_max ao_out_max


###############################################################################
# AO4 / AO5 (20-bit CN0531) packed configuration
# Independent of existing AO0..AO3, AXI clock domain shadow registers.
# Transferred to adc_test_clk domain by existing APPLY logic in system_top.
###############################################################################

create_bd_port -dir O -from 5 -to 0 ao20_source_sel
create_bd_port -dir O -from 39 -to 0 ao20_manual_code
create_bd_port -dir O -from 63 -to 0 ao20_gain
create_bd_port -dir O -from 63 -to 0 ao20_offset
create_bd_port -dir O -from 63 -to 0 ao20_out_min
create_bd_port -dir O -from 63 -to 0 ao20_out_max

ad_connect app_ctrl_0/ao20_source_sel ao20_source_sel
ad_connect app_ctrl_0/ao20_manual_code ao20_manual_code
ad_connect app_ctrl_0/ao20_gain ao20_gain
ad_connect app_ctrl_0/ao20_offset ao20_offset
ad_connect app_ctrl_0/ao20_out_min ao20_out_min
ad_connect app_ctrl_0/ao20_out_max ao20_out_max


###############################################################################
# Live AO stream input
###############################################################################

create_bd_port -dir I -from 63 -to 0 ao_output
ad_connect ao_output control_stream_serializer_0/ao_output
