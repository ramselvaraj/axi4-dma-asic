# Run from the repository root:  dc_shell -f synth/dc.tcl   (or: make dc)
# Source synth/env.sh first. TARGET_LIBRARY is a Tcl list of absolute .db paths.
#
# DC_ELAB_ONLY=1    stop after elaboration and check_design
# DC_REPORT_ONLY=1  reload the mapped DDC and rewrite the diagnostic reports
# DC_OUT_DIR=path   output directory (default synth/build)

set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $script_dir]

proc env_or {name fallback} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $fallback
}

proc constraint_value {name fallback} {
    set value [env_or $name $fallback]
    if {![string is double -strict $value] || !($value >= 0 && $value < 1e9)} {
        error "$name must be a finite nonnegative number."
    }
    return $value
}

proc report_diagnostics {} {
    redirect -file reports/timing_hold.rpt {
        report_timing -delay_type min -max_paths 10 -significant_digits 6
    }
    redirect -file reports/constraints_detailed.rpt {
        report_constraint -all_violators -significant_digits 6
    }
    redirect -file reports/clock.rpt {report_clock -attributes}
    redirect -file reports/ports.rpt {report_port -verbose [get_ports *]}
    redirect -file reports/check_timing.rpt {check_timing}
    write_sdc results/constraints_diagnostic.sdc
}

proc run_synthesis {} {
    global repo_dir script_dir
    set top dma_top

    set libraries [env_or TARGET_LIBRARY {}]
    if {[llength $libraries] == 0} {
        error "Set TARGET_LIBRARY (source synth/env.sh)."
    }
    set extra_libraries [env_or LINK_LIBRARY {}]
    foreach library [concat $libraries $extra_libraries] {
        if {![file isfile $library] || [file pathtype $library] ne "absolute"} {
            error "Library must be an existing absolute path: $library"
        }
    }

    set output_dir [file normalize [env_or DC_OUT_DIR [file join $repo_dir synth build]]]
    file mkdir $output_dir
    cd $output_dir
    file mkdir work reports results
    define_design_lib WORK -path [file join $output_dir work]

    set_app_var target_library $libraries
    set_app_var synthetic_library [list dw_foundation.sldb]
    set_app_var link_library [concat [list *] $libraries $extra_libraries [list dw_foundation.sldb]]

    if {[env_or DC_REPORT_ONLY 0] eq "1"} {
        if {![file isfile results/${top}.ddc]} {
            error "No mapped DDC in $output_dir/results. Run synthesis first."
        }
        read_ddc results/${top}.ddc
        current_design $top
        if {![link]} {error "Cannot link the saved mapped design."}
        report_diagnostics
        puts "Diagnostic reports complete: $output_dir/reports"
        return
    }

    set fd [open [file join $repo_dir rtl files.txt] r]
    set manifest [read $fd]
    close $fd
    set rtl_sources {}
    foreach line [split $manifest "\n"] {
        set line [string trim $line]
        if {$line ne "" && ![string match "#*" $line]} {
            lappend rtl_sources [file join $repo_dir $line]
        }
    }

    if {![analyze -format sverilog -define [list SYNTHESIS] $rtl_sources]} {
        error "RTL analysis failed."
    }
    elaborate $top
    current_design $top
    if {![link]} {
        error "Design linking failed. Check the libraries and unresolved references."
    }
    uniquify
    source [file join $script_dir constraints.tcl]

    redirect -file reports/check_elaborated.rpt {set design_ok [check_design]}
    if {!$design_ok} {
        error "Elaborated design failed check_design. See reports/check_elaborated.rpt."
    }
    write -format ddc -hierarchy -output results/${top}_elaborated.ddc
    if {[env_or DC_ELAB_ONLY 0] eq "1"} {
        puts "Elaboration complete: $output_dir"
        return
    }

    # Keep hierarchy so the area report shows FIFO, engines and registers apart.
    if {![compile_ultra -no_autoungroup]} {
        error "Technology mapping failed."
    }
    redirect -file reports/check_mapped.rpt {set design_ok [check_design]}
    if {!$design_ok} {
        error "Mapped design failed check_design. See reports/check_mapped.rpt."
    }
    change_names -rules verilog -hierarchy
    write -format ddc -hierarchy -output results/${top}.ddc
    write -format verilog -hierarchy -output results/${top}.v
    write_sdc results/${top}.sdc
    redirect -file reports/area.rpt {report_area -hierarchy}
    redirect -file reports/timing.rpt {report_timing -delay_type max -max_paths 20}
    redirect -file reports/constraints.rpt {report_constraint -all_violators}
    redirect -file reports/qor.rpt {report_qor}
    redirect -file reports/resources.rpt {report_resources -hierarchy}
    report_diagnostics
    puts "Synthesis complete: $output_dir"
}

if {[catch {run_synthesis} message]} {
    puts stderr "ERROR: $message"
    exit 1
}
exit 0
