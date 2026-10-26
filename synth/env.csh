# csh/tcsh setup for the ADDV lab server (same as RAPTOR-SoC).
# From the repository root: source synth/env.csh
# Existing environment settings take precedence.

if (! $?DC_HOME) then
    setenv DC_HOME /usr/local2/synopsys/syn_2023.12-SP51
endif
if (! $?PDK_DIR) then
    setenv PDK_DIR /usr/local2/cadence/NCSU/SRC/FreePDK45
endif
if (! $?SNPSLMD_LICENSE_FILE) then
    setenv SNPSLMD_LICENSE_FILE 27020@enlicense5.eas.asu.edu
endif
if (! $?LM_LICENSE_FILE) then
    setenv LM_LICENSE_FILE "$SNPSLMD_LICENSE_FILE"
endif
if (! $?TARGET_LIBRARY) then
    setenv TARGET_LIBRARY "${PDK_DIR}/osu_soc/lib/files/gscl45nm.db"
endif
# Two clocks: read side (SoC/SRAM) and write side (DDR user clock), in ns.
if (! $?DC_RD_PERIOD) then
    setenv DC_RD_PERIOD 10.0
endif
if (! $?DC_WR_PERIOD) then
    setenv DC_WR_PERIOD 8.0
endif

# Repeated sourcing must not add duplicate PATH entries.
if ( ":${PATH}:" !~ *":${DC_HOME}/bin:"* ) then
    setenv PATH "${DC_HOME}/bin:${PATH}"
endif

if (! -x "${DC_HOME}/bin/dc_shell") then
    echo "Warning: dc_shell is not at DC_HOME/bin/dc_shell. Check DC_HOME on the lab server."
endif
