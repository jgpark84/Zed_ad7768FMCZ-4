open_project ad7768evb_zed.xpr

foreach r {synth_1 system_app_ctrl_0_0_synth_1 system_axi_cpu_interconnect_imp_auto_pc_0_synth_1} {
  set rr [get_runs $r]
  puts "$r"
  puts "  STATUS   = [get_property STATUS $rr]"
  puts "  PROGRESS = [get_property PROGRESS $rr]"
  puts "  NEEDS_REFRESH = [get_property NEEDS_REFRESH $rr]"
}

close_project
exit
