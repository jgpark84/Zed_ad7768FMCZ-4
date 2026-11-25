open_project ad7768evb_zed.xpr

launch_runs impl_1 -to_step write_bitstream
wait_on_run impl_1

puts "IMPL STATUS = [get_property STATUS [get_runs impl_1]]"
puts "IMPL PROGRESS = [get_property PROGRESS [get_runs impl_1]]"

close_project
exit
