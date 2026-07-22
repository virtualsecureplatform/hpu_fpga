#!/bin/bash
# ==============================================================================================
# BSD 3-Clause Clear License
# Copyright © 2025 ZAMA. All rights reserved.
# ----------------------------------------------------------------------------------------------
# Description  : Bring-up / debug for the MHDMA packet-trace buffer (mhdma_pkt_trace).
#
#   The trace buffer circularly captures decoded packet headers (+ FSM state, error bits and a
#   relative timestamp). On the first mhdma-domain error it keeps capturing TRACE_DEPTH/2 more
#   headers then freezes, so the frozen ring holds ~half the headers from before the fault and
#   ~half from after. Software re-arms it (WRITE trace_ctrl), polls the frozen bit (READ
#   trace_ctrl) and pops the ring one 32-bit word at a time (READ trace_data).
#
#   This script exercises the whole register path on board:
#     status   - read trace_ctrl (frozen + wptr) and the errors register
#     arm      - flush + re-arm capture, assert it comes back un-frozen
#     dump     - read the frozen ring and decode it oldest->newest
#     wait     - poll until frozen (bounded), then dump
#     selftest - arm, run benign traffic, assert capture does NOT falsely freeze (regression),
#                then leave it armed to catch the next real fault
# ==============================================================================================
# Usage: ./mhdma_trace.sh [-f <board>] <status|arm|dump|wait|selftest> [args]

trap 'kill $(jobs -p) 2>/dev/null; exit 0' SIGINT SIGTERM

source /etc/profile.d/v80_pcie_dev.sh
source "$(dirname "$0")/mhdma_package.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- trace geometry (mirror mhdma_pkg.sv) -----------------------------------------------------
TRACE_DEPTH=64          # localparam int TRACE_DEPTH
WORDS_PER_ENTRY=4       # TRACE_W / REG_DATA_W = 128/32
TOTAL_WORDS=$((TRACE_DEPTH * WORDS_PER_ENTRY))

# errors[13:0] bit -> label (mirrors mhdma_system::errors). The trace entry only captures the
# mhdma-clock bits [11:0] (word3[11:0]); the cfg-clock bits [13:12] are errors-register only.
ERR_LABEL=(
  "hpu_onehot_id_violation"   # 0
  "hbm_write_error_pc0"       # 1  (per-PC AXI4 HBM write error [2:1])
  "hbm_write_error_pc1"       # 2
  "ct_seq_num_mismatch"       # 3
  "master_max_retry_notify"   # 4
  "master_max_retry_rreq"     # 5
  "hbm_read_resp_error"       # 6
  "slave_rreq_cmdq_ovf"       # 7
  "decoder_rx_fifo_ovf"       # 8
  "formatter_payload_gap"     # 9
  "formatter_slave_discard"   # 10
  "formatter_master_discard"  # 11
  "master_notify_cmdq_ovf"    # 12 (cfg-clock; errors register only, not in trace)
  "master_rreq_cmdq_ovf"      # 13 (cfg-clock; errors register only, not in trace)
)

# --------------------------------------------------------------------------------------------- #
# HELPERS
# --------------------------------------------------------------------------------------------- #

# Read a register and return its value as a plain decimal integer.
# mhdma_reg_read (BAR0 via ami_tool) already returns a clean "0xN" string.
reg_read_dec() {
  local board=$1 reg=$2 val
  val=$(mhdma_reg_read "$board" "$reg") || { echo "[ERROR] read of $reg failed" >&2; return 1; }
  echo $(( val ))
}

# Bit-field extract: extract_field <value> <lsb> <width>
extract_field() {
  local value=$1 lsb=$2 width=$3
  echo $(( (value >> lsb) & ((1 << width) - 1) ))
}

# Decode + print the errors bitmap (used for both the errors register and a trace entry).
print_errors() {
  local errbits=$1 prefix=$2 any=0 i
  for ((i = 0; i < ${#ERR_LABEL[@]}; i++)); do
    if (( (errbits >> i) & 1 )); then
      printf "%s[%d] %s\n" "$prefix" "$i" "${ERR_LABEL[$i]}"
      any=1
    fi
  done
  [ "$any" -eq 0 ] && printf "%s(none)\n" "$prefix"
}

# --------------------------------------------------------------------------------------------- #
# COMMANDS
# --------------------------------------------------------------------------------------------- #

# Read trace_ctrl -> frozen (bit0), wptr (bits[6:1]), wrapped (bit7), plus the errors register.
cmd_status() {
  local board=$1
  local ctrl frozen wptr wrapped errbits
  ctrl=$(reg_read_dec "$board" mhdma_system::trace_ctrl)
  frozen=$(extract_field "$ctrl" 0 1)
  wptr=$(extract_field "$ctrl" 1 6)
  wrapped=$(extract_field "$ctrl" 7 1)
  errbits=$(reg_read_dec "$board" mhdma_system::errors)

  echo "=== MHDMA trace status (board $board) ==="
  printf "  trace_ctrl = 0x%08x\n" "$ctrl"
  printf "  frozen     = %d %s\n" "$frozen" "$([ "$frozen" -eq 1 ] && echo '(buffer FROZEN, ready to read)' || echo '(armed / capturing)')"
  printf "  wptr       = %d (oldest entry index at freeze)\n" "$wptr"
  printf "  wrapped    = %d %s\n" "$wrapped" "$([ "$wrapped" -eq 1 ] && echo '(ring FULL: all entries valid, rotate by wptr)' || echo '(PARTIAL: only entries [0..wptr-1] valid, rest stale)')"
  printf "  errors     = 0x%04x\n" "$errbits"
  print_errors "$errbits" "    "
}

# Flush + re-arm: WRITE trace_ctrl (any value), then confirm frozen cleared.
cmd_arm() {
  local board=$1
  echo "[INFO] Arming trace buffer on board $board ..."
  mhdma_reg_write "$board" mhdma_system::trace_ctrl 0x1 > /dev/null
  # give the arm strobe time to cross into clk_mhdma and flush the stale frozen (CDC, 4 stages)
  sleep 0.1
  local ctrl frozen wptr
  ctrl=$(reg_read_dec "$board" mhdma_system::trace_ctrl)
  frozen=$(extract_field "$ctrl" 0 1)
  wptr=$(extract_field "$ctrl" 1 6)
  if [ "$frozen" -ne 0 ]; then
    echo "[FAIL] board $board: frozen=$frozen after arm (expected 0). Re-arm/CDC path broken, or an error is asserted continuously (see 'errors')."
    return 1
  fi
  if [ "$wptr" -ne 0 ]; then
    echo "[WARN] board $board: wptr=$wptr right after arm (a header was captured between arm and read-back; usually fine)."
  fi
  echo "[PASS] board $board: trace armed (frozen=0)."
  return 0
}

# Read the whole frozen ring and decode it oldest->newest (rotated by wptr).
cmd_dump() {
  local board=$1
  local ctrl frozen wptr wrapped
  ctrl=$(reg_read_dec "$board" mhdma_system::trace_ctrl)
  frozen=$(extract_field "$ctrl" 0 1)
  wptr=$(extract_field "$ctrl" 1 6)
  wrapped=$(extract_field "$ctrl" 7 1)

  if [ "$frozen" -ne 1 ]; then
    echo "[WARN] board $board: buffer is NOT frozen (frozen=0). Contents are still being overwritten;"
    echo "       dump only makes sense after a freeze. Use 'wait' to block until a fault freezes it."
  fi

  # wrapped=1 : ring is full, TRACE_DEPTH valid entries, oldest at wptr (rotate).
  # wrapped=0 : partial fill, only entries [0..wptr-1] valid (in order); the rest are stale
  #             prior-session data and must NOT be shown.
  local n_valid first
  if [ "$wrapped" -eq 1 ]; then
    n_valid=$TRACE_DEPTH
    first=$wptr
    echo "[INFO] board $board: ring FULL, dumping $n_valid entries (wptr=$wptr -> oldest)"
  else
    n_valid=$wptr
    first=0
    echo "[INFO] board $board: ring PARTIAL, dumping $n_valid valid entries [0..$((wptr - 1))] (rest stale, not shown)"
  fi

  # Pop TOTAL_WORDS words; the read pointer auto-increments on every trace_data read. We always pop
  # the whole ring so words[] is indexed by absolute entry, then only decode the valid ones.
  local words=()
  local i
  for ((i = 0; i < TOTAL_WORDS; i++)); do
    words[$i]=$(reg_read_dec "$board" mhdma_system::trace_data)
  done

  local errbits_reg
  errbits_reg=$(reg_read_dec "$board" mhdma_system::errors)

  echo ""
  echo "  ord  entry | src_mac   hpu iop req md flag seq |  src_addr dst_addr | ts   fsm(fmt,cem,nrx,brst,rreq,ntfy) | errors"
  echo "  ---------------------------------------------------------------------------------------------------------------------"
  local ord e base w0 w1 w2 w3
  for ((ord = 0; ord < n_valid; ord++)); do
    e=$(( (first + ord) % TRACE_DEPTH ))
    base=$(( e * WORDS_PER_ENTRY ))
    w0=${words[$base]}
    w1=${words[$((base + 1))]}
    w2=${words[$((base + 2))]}
    w3=${words[$((base + 3))]}

    # command_t (96b) = {w2, w1, w0}
    local dst_addr src_addr iop req mode flag hpu seq src_mac
    dst_addr=$(extract_field "$w0" 0 16)
    src_addr=$(extract_field "$w0" 16 16)
    iop=$(extract_field "$w1" 0 8)
    req=$(extract_field "$w1" 8 4)
    mode=$(extract_field "$w1" 12 2)
    flag=$(extract_field "$w1" 14 6)
    hpu=$(extract_field "$w1" 28 4)
    seq=$(extract_field "$w2" 0 8)
    src_mac=$(extract_field "$w2" 8 24)

    # word3 = {ts[6:0]@25, fsm[12:0]@12, err[11:0]@0}   (err = mhdma_error_t, 12 bits, ETH_PC=2)
    local errbits fsm ts
    errbits=$(extract_field "$w3" 0 12)
    fsm=$(extract_field "$w3" 12 13)
    ts=$(extract_field "$w3" 25 7)
    # fsm[12:0] = {fmt[2:0], cem[1:0], nrx[1:0], burst[1:0], rreq[1:0], ntfy[1:0]}
    local f_fmt f_cem f_nrx f_brst f_rreq f_ntfy
    f_ntfy=$(extract_field "$fsm" 0 2)
    f_rreq=$(extract_field "$fsm" 2 2)
    f_brst=$(extract_field "$fsm" 4 2)
    f_nrx=$(extract_field "$fsm" 6 2)
    f_cem=$(extract_field "$fsm" 8 2)
    f_fmt=$(extract_field "$fsm" 10 3)

    local mark=" "
    [ "$errbits" -ne 0 ] && mark="*"   # entry captured with a live error bit set

    printf "%s %3d  %5d | 0x%06x  %2d  %3d  %2d  %d  0x%02x %3d | 0x%04x   0x%04x | %3d  %d,%d,%d,%d,%d,%d          | 0x%03x\n" \
      "$mark" "$ord" "$e" "$src_mac" "$hpu" "$iop" "$req" "$mode" "$flag" "$seq" \
      "$src_addr" "$dst_addr" "$ts" "$f_fmt" "$f_cem" "$f_nrx" "$f_brst" "$f_rreq" "$f_ntfy" "$errbits"
  done
  echo "  ---------------------------------------------------------------------------------------------------------------------"
  echo "  (* = entry captured while an error bit was live; these mark the tail after the trigger)"
  echo ""
  printf "  errors register now = 0x%04x\n" "$errbits_reg"
  print_errors "$errbits_reg" "    "
}

# Poll trace_ctrl until frozen, then dump. Bounded by <timeout_s> (default 10s).
cmd_wait() {
  local board=$1 timeout_s=${2:-10}
  echo "[INFO] board $board: waiting up to ${timeout_s}s for the trace buffer to freeze ..."
  local deadline=$((SECONDS + timeout_s)) frozen=0 ctrl
  while [ "$SECONDS" -lt "$deadline" ]; do
    ctrl=$(reg_read_dec "$board" mhdma_system::trace_ctrl)
    frozen=$(extract_field "$ctrl" 0 1)
    if [ "$frozen" -eq 1 ]; then
      echo "[INFO] board $board: FROZEN detected."
      cmd_dump "$board"
      return 0
    fi
    sleep 0.2
  done
  echo "[TIMEOUT] board $board: buffer did not freeze within ${timeout_s}s (no mhdma error occurred)."
  return 1
}

# Regression: arm, drive benign traffic, assert the buffer does NOT falsely freeze.
# This is the key property of the feature: capture is silent until a real error.
cmd_selftest() {
  local board=$1 ncards=${2:-0}
  echo "=================================================================================================="
  echo "  MHDMA trace self-test (board $board)"
  echo "=================================================================================================="

  # 1) arm and confirm un-frozen
  cmd_arm "$board" || return 1

  # 2) confirm no error is currently latched (a sticky error would immediately re-freeze)
  local errbits
  errbits=$(reg_read_dec "$board" mhdma_system::errors)
  if [ "$errbits" -ne 0 ]; then
    echo "[WARN] board $board: errors=0x$(printf '%03x' "$errbits") already set before traffic;"
    echo "       the buffer is expected to (re)freeze. Inspect with: $0 -f $board dump"
  fi

  # 3) drive benign traffic if we have a multi-card ring available
  if [ "$ncards" -ge 2 ] && [ -x "$SCRIPT_DIR/mhdma_notify.sh" ]; then
    echo "[INFO] Driving benign ring-notify traffic across $ncards cards ..."
    "$SCRIPT_DIR/mhdma_notify.sh" "$ncards" 50 > /dev/null 2>&1 || true
  else
    echo "[INFO] No traffic driver requested (pass a card count >=2 to generate notify traffic)."
    echo "       Sleeping 2s to let any in-flight traffic run."
    sleep 2
  fi

  # 4) capture must still be armed (frozen == 0) if no error occurred
  local ctrl frozen
  ctrl=$(reg_read_dec "$board" mhdma_system::trace_ctrl)
  frozen=$(extract_field "$ctrl" 0 1)
  errbits=$(reg_read_dec "$board" mhdma_system::errors)

  if [ "$frozen" -eq 1 ]; then
    if [ "$errbits" -ne 0 ]; then
      echo "[INFO] board $board: buffer froze AND errors=0x$(printf '%03x' "$errbits") is set."
      echo "       This is correct behavior (an mhdma error was captured). Dumping the ring:"
      cmd_dump "$board"
      return 0
    fi
    echo "[FAIL] board $board: buffer FROZE with errors=0 -> FALSE TRIGGER. error_detected wiring is suspect."
    return 1
  fi

  if [ "$errbits" -ne 0 ]; then
    echo "[FAIL] board $board: errors=0x$(printf '%03x' "$errbits") set but buffer never froze -> freeze path broken."
    return 1
  fi

  echo "[PASS] board $board: benign traffic ran, no error, buffer stayed armed (no false freeze). Left armed."
  return 0
}

# --------------------------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------------------------- #
usage() {
  echo "Usage: $0 [-f <board>] <command> [args]"
  echo ""
  echo "  -f <board>   board index (default 0)"
  echo ""
  echo "Commands:"
  echo "  status                 read frozen/wptr + errors register"
  echo "  arm                    flush + re-arm capture, assert it comes back un-frozen"
  echo "  dump                   read the frozen ring and decode oldest->newest"
  echo "  wait [timeout_s]       poll until frozen (default 10s), then dump"
  echo "  selftest [ncards]      arm, run benign traffic (ncards>=2), assert no false freeze"
  echo ""
  echo "Examples:"
  echo "  $0 -f 0 selftest 2     # arm board 0, drive 2-card notify traffic, check no false freeze"
  echo "  $0 -f 0 wait 30        # provoke a fault by hand, then block up to 30s and dump the ring"
  exit 1
}

BOARD=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -f|--board) BOARD="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) break ;;
  esac
done

CMD="$1"; shift

if ! mhdma_check_ami; then
  exit 1
fi
if ! _mhdma_board_valid "$BOARD"; then
  echo "[ERROR] Board $BOARD is not configured in V80_BOARDS_MAP (pcie_id=x)."
  exit 1
fi

case "$CMD" in
  status)   cmd_status   "$BOARD" ;;
  arm)      cmd_arm      "$BOARD" ;;
  dump)     cmd_dump     "$BOARD" ;;
  wait)     cmd_wait     "$BOARD" "$@" ;;
  selftest) cmd_selftest "$BOARD" "$@" ;;
  *)        usage ;;
esac
