set projects [glob -nocomplain *.xpr]
if {[llength $projects] != 1} {
    error "Expected one XPR project, found: $projects"
}

open_project [lindex $projects 0]
open_run impl_1

foreach p {
    cn0531_jc_sync_n
    cn0531_jc_sclk
    cn0531_jc_sdin
    cn0531_jc_ldac_n
    cn0531_jc_reset_n
    cn0531_jc_clr_n
    cn0531_jd_sync_n
    cn0531_jd_sclk
    cn0531_jd_sdin
    cn0531_jd_ldac_n
    cn0531_jd_reset_n
    cn0531_jd_clr_n
} {
    set port [get_ports -quiet $p]
    if {[llength $port] == 0} {
        puts "MISSING: $p"
    } else {
        puts "$p : [get_property PACKAGE_PIN $port] / [get_property IOSTANDARD $port]"
    }
}

foreach p {cn0531_jc_sync_n cn0531_jc_sclk cn0531_jc_ldac_n cn0531_jd_sync_n cn0531_jd_sclk cn0531_jd_ldac_n} {
    puts "IO_DIR $p = [get_property DIRECTION [get_ports $p]]"
}
close_project
