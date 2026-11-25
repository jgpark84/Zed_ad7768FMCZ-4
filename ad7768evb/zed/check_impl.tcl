open_project ad7768evb_zed.xpr

set r [get_runs impl_1]

puts "STATUS   = [get_property STATUS $r]"
puts "PROGRESS = [get_property PROGRESS $r]"
puts "NEEDS_REFRESH = [get_property NEEDS_REFRESH $r]"

close_project
exit
