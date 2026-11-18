| Area | Mutant | Result | First check that fired (config, seed: message) |
|---|---|---|---|
| burst | `no_4k_clamp` | KILLED | aw3 seed 1: AW burst crosses NKB |
| burst | `max_beats_17` | KILLED | aw3 seed 1: AR burst longer than N beats |
| burst | `no_remaining_clamp` | KILLED | aw3 seed 1: DN warmup: timeout waiting for irq |
| burst | `page_calc_off_by_8` | KILLED | aw3 seed 1: AW burst crosses NKB |
| read | `rd_arlen_off_by_one` | KILLED | aw3 seed 1: DN warmup: read N bytes expected N |
| read | `rd_cur_step_fixed` | KILLED | aw3 seed 1: AR not contiguous: got N exp N |
| read | `rd_rem_step_fixed` | KILLED | aw3 seed 1: DN: second START was not ignored |
| read | `rd_busy_clears_early` | KILLED | aw3 seed 1: RN src=N dst=N len=N: timeout waiting for irq |
| read | `rd_araddr_plus8` | KILLED | aw3 seed 1: AR not contiguous: got N exp N |
| read | `rd_arvalid_drops` | KILLED | aw3 seed 1: AR changed or dropped before arready |
| read | `rd_err_never_set` | KILLED | aw3 seed 1: RN src=N dst=N len=N: rd_err=N expected N |
| read | `rd_err_only_decerr` | KILLED | aw3 seed 1: RN src=N dst=N len=N: rd_err=N expected N |
| read | `rd_err_not_cleared` | KILLED | aw3 seed 1: RN src=N dst=N len=N: rd_err=N expected N |
| read | `rd_rready_ignores_fifo` | KILLED | aw3 seed 1: FIFO overflow |
| read | `rd_winc_ignores_ready` | KILLED | aw3 seed 1: FIFO overflow |
| read | `rd_start_ignored_busy` | KILLED | aw3 seed 1: AR changed or dropped before arready |
| write | `wr_awlen_off_by_one` | KILLED | aw3 seed 1: WLAST wrong |
| write | `wr_awaddr_plus8` | KILLED | aw3 seed 1: AW not contiguous: got N exp N |
| write | `wr_cur_step_fixed` | KILLED | aw3 seed 1: AW not contiguous: got N exp N |
| write | `wr_rem_step_fixed` | KILLED | aw3 seed 1: DN warmup: timeout waiting for irq |
| write | `wr_wlast_early` | KILLED | aw3 seed 1: WLAST wrong |
| write | `wr_wstrb_partial` | KILLED | aw3 seed 1: WSTRB not all ones |
| write | `wr_bready_always` | SURVIVED | - |
| write | `wr_b_response_skipped` | KILLED | aw3 seed 1: RN src=N dst=N len=N: timeout waiting for irq |
| write | `wr_err_never_set` | KILLED | aw3 seed 1: RN src=N dst=N len=N: wr_err=N expected N |
| write | `wr_wvalid_ignores_empty` | KILLED | aw3 seed 1: W changed or dropped before wready |
| write | `wr_rinc_ignores_ready` | KILLED | aw3 seed 1: W changed or dropped before wready |
| write | `wr_cnt_load_minus1` | KILLED | aw3 seed 1: WLAST wrong |
| write | `wr_done_one_burst_early` | KILLED | aw3 seed 1: RN src=N dst=N len=N: AW covers N bytes expected N |
| write | `wr_aw_not_held` | KILLED | aw3 seed 1: AW changed or dropped before awready |
| write | `wr_err_not_cleared` | KILLED | aw3 seed 1: RN src=N dst=N len=N: wr_err=N expected N |
| regs | `regs_src_not_locked` | KILLED | aw3 seed 1: DN: SRC changed while busy |
| regs | `regs_dst_not_locked` | KILLED | aw3 seed 1: DN: DST changed while busy |
| regs | `regs_len_not_locked` | KILLED | aw3 seed 1: DN: LEN changed while busy |
| regs | `regs_start_while_busy` | KILLED | aw3 seed 1: AR not contiguous: got N exp N |
| regs | `regs_zero_len_ok` | KILLED | aw3 seed 1: AR burst longer than N beats |
| regs | `regs_len_align_ok` | KILLED | aw3 seed 1: AR not contiguous: got N exp N |
| regs | `regs_src_align_ok` | KILLED | aw3 seed 1: AR address not N-byte aligned |
| regs | `regs_dst_align_ok` | KILLED | aw3 seed 1: AR not contiguous: got N exp N |
| regs | `regs_w1c_inverted` | KILLED | aw3 seed 1: DN warmup: still busy after irq |
| regs | `regs_irq_en_ignored` | KILLED | aw3 seed 1: DN: irq high while masked |
| regs | `regs_done_not_cleared` | KILLED | aw3 seed 1: DN: STATUS=N while running, expected busy=N done=N |
| regs | `regs_err_bits_dropped` | KILLED | aw3 seed 1: RN src=N dst=N len=N: wr_err=N expected N |
| regs | `regs_err_irq_missing` | KILLED | aw3 seed 1: RN src=N dst=N len=N: IRQ_STATUS.err=N wrong |
| regs | `regs_cfg_err_no_irq` | KILLED | aw3 seed 1: DN.N: no error irq |
| regs | `regs_busy_stuck` | KILLED | aw3 seed 1: DN warmup: still busy after irq |
| regs | `regs_start_never_fires` | KILLED | aw3 seed 1: DN warmup: timeout waiting for irq |
| regs | `regs_status_bits_swapped` | KILLED | aw3 seed 1: DN warmup: still busy after irq |
| regs | `regs_done_irq_missing` | KILLED | aw3 seed 1: DN warmup: timeout waiting for irq |
| regs | `regs_src_readback_dst` | KILLED | aw3 seed 1: DN: SRC changed while busy |
| regs | `regs_bresp_slverr` | KILLED | aw3 seed 1: AXI-Lite write response not OKAY |
| regs | `regs_rresp_slverr` | KILLED | aw3 seed 1: AXI-Lite read response not OKAY |
| regs | `regs_reset_missing` | KILLED | aw3 seed 1: DN.N: SRC not cleared |
| top | `top_wr_err_dropped` | KILLED | aw3 seed 1: RN src=N dst=N len=N: wr_err=N expected N |
| top | `top_done_never` | KILLED | aw3 seed 1: DN warmup: timeout waiting for irq |
| cdc | `cdc_pulse_one_ff` | SURVIVED | - |
| cdc | `cdc_pulse_no_toggle` | KILLED | aw3 seed 1: DN: timeout |
| fifo | `fifo_full_alias_empty` | KILLED | aw3 seed 1: DN warmup: timeout waiting for irq |
| fifo | `fifo_never_empty` | KILLED | aw3 seed 1: W changed or dropped before wready |
| fifo | `fifo_never_full` | KILLED | aw3 seed 1: W changed or dropped before wready |
| fifo | `fifo_binary_wptr_crosses` | KILLED | aw3 seed 1: W changed or dropped before wready |
| fifo | `fifo_write_slot_off` | KILLED | aw3 seed 1: DN warmup: N words wrong inside destination |
| fifo | `fifo_read_index_gray` | KILLED | aw3 seed 1: DN warmup: N words wrong inside destination |
| fifo | `fifo_read_when_empty` | SURVIVED | - |
| fifo | `fifo_write_when_full` | SURVIVED | - |
