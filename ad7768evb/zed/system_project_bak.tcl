###############################################################################
## Copyright (C) 2014-2024 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

source ../../../scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl

adi_project ad7768evb_zed
adi_project_files ad7768evb_zed [list \
  "system_top.v" \
  "da3_driver.v" \
  "app_ctrl.v" \
  "app_ctrl_reg.v" \
  "avg4ch_prog.v" \
  "cordic_atan2.v" \
  "pid_core.v" \
  "input_normalizer.v" \
  "ao_scaler.v" \
  "$ad_hdl_dir/library/common/up_axi.v" \
  "system_constr.xdc" \
  "$ad_hdl_dir/projects/common/zed/zed_system_constr.xdc" \
  "$ad_hdl_dir/library/common/ad_iobuf.v" ]

adi_project_run ad7768evb_zed