#!/bin/bash

# ─────────────────────────────────────────────────────────────
# Simplified Test for user-provided spec_havoc.S
# Observes system impact (temp/freq) of the spec_havoc tool.
# Analogy: Intense, specific CPU core stress.
# !!! FOR TEST MACHINES !!!
# ─────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then echo "[ERROR] Please run as root or with sudo." >&2; exit 1; fi
set -euo pipefail

# --- Configuration ---
HAVOC_DURATION_S=60      # How long to run spec_havoc
MONITOR_INTERVAL_S=1

RUN_ID="spec_havoc_test_$(date +%Y%m%d_%H%M%S)"
DATA_DIR="${RUN_ID}"
mkdir -p "$DATA_DIR"
LOGFILE="${DATA_DIR}/spec_havoc_run.log"
HAVOC_DATA_CSV="${DATA_DIR}/spec_havoc_telemetry_data.csv"
HAVOC_S_FILE="provided_spec_havoc.S" # EXPECTING YOUR spec_havoc.S
HAVOC_O_FILE="${DATA_DIR}/spec_havoc.o"
HAVOC_EXE="${DATA_DIR}/spec_havoc_compiled"

# --- Functions (re-use log_message, install_packages_minimal, get_cpu_freq_khz, get_cpu_temp_c from hammer script) ---
log_message() { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"; echo "$msg" | tee -a "$LOGFILE" >&2; }
get_cpu_freq_khz() { freq_mhz=$(lscpu -p=CPU,MHZ | grep -E '^[0-9]+,' | head -n1 | awk -F, '{print $2}' 2>/dev/null); if [[ "$freq_mhz" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then printf "%.0f000" "$freq_mhz"; return; fi; if [ -r /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq ]; then cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || echo "N/A"; elif [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A"; else echo "N/A"; fi; }
get_cpu_temp_c() { local temp_val="N/A"; if command -v sensors &>/dev/null; then temp_val=$(sensors 2>/dev/null | grep -iE 'Package id 0:|Core 0:|Tdie:|temp1:.*\(CRIT|temp1_input:' | head -n1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^\+[0-9]+(\.[0-9]+)?°C$/) {sub(/^\+/,"",$i); sub(/°C$/,"",$i); print $i; exit}}'); fi; if [[ -z "$temp_val" || "$temp_val" == "N/A" ]] && command -v sensors &>/dev/null; then temp_val=$(sensors 2>/dev/null | awk '/\+[0-9]+\.[0-9]+°C/ {gsub(/^\+/,""); gsub(/°C$/,""); print $0; exit}' | awk '{print $1}'); fi; [ -z "$temp_val" ] || [[ ! "$temp_val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && temp_val="N/A"; echo "$temp_val"; }
install_packages_minimal() {
    local missing_pkgs=()
    local essential_packages=(binutils gcc lm-sensors coreutils bc) # For compiling assembly
    for pkg in "${essential_packages[@]}"; do
        local cmd_check="${pkg%%-*}"; if [ "$pkg" == "lm-sensors" ]; then cmd_check="sensors"; elif [ "$pkg" == "binutils" ]; then cmd_check="as"; fi
        if ! command -v "$cmd_check" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null; then missing_pkgs+=("$pkg"); fi
    done
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_message "[+] Installing missing packages: ${missing_pkgs[*]}"
        if command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y -qq "${missing_pkgs[@]}"; else log_message "[ERROR] Please install: ${missing_pkgs[*]}"; exit 1; fi
    fi
     if command -v sensors-detect &>/dev/null && ! (sensors | grep -qE 'Adapter|Core|temp'); then yes | sensors-detect >/dev/null 2>&1; fi
}
_CLEANUP_RUNNING=0
cleanup() {
  if [ "$_CLEANUP_RUNNING" -ne 0 ]; then return; fi; _CLEANUP_RUNNING=1
  log_message "[*] Cleaning up ${HAVOC_EXE##*/} ..."
  pkill -f "${HAVOC_EXE##*/}" 2>/dev/null || true # Kill by name
  if [ -n "${havoc_pid:-}" ] && ps -p "$havoc_pid" > /dev/null; then kill "$havoc_pid" 2>/dev/null || true; sleep 0.5; kill -9 "$havoc_pid" 2>/dev/null || true; fi
  rm -f "$HAVOC_O_FILE" "$HAVOC_EXE"
  log_message "[*] Cleanup finished."
  _CLEANUP_RUNNING=0
}
trap cleanup EXIT INT TERM

# --- Main ---
install_packages_minimal
log_message "=== Simplified Test for spec_havoc.S ==="

if [ ! -f "$HAVOC_S_FILE" ]; then
    log_message "[ERROR] $HAVOC_S_FILE not found. Please place your Assembly source file here."
    cat > "$HAVOC_S_FILE" << 'DEFAULT_SPEC_HAVOC_EOF'
.section .text;.global _start;_start:vmovaps %ymm0,%ymm1;vmovaps %ymm0,%ymm2;vmovaps %ymm0,%ymm3;vmovaps %ymm0,%ymm4;vmovaps %ymm0,%ymm5;vmovaps %ymm0,%ymm6;vmovaps %ymm0,%ymm7;xor %r12,%r12;mov $200000000,%r13;xor %r14,%r14;mov $0x5555555555555555,%rax;mov $0xaaaaaaaaaaaaaaaa,%rbx;mov $0x3333333333333333,%rcx;mov $0xcccccccccccccccc,%rdx;.main_loop:inc %r14;cmp %r13,%r14;jge .exit;test $0x1FFF,%r14;jnz .skip_phase_change;inc %r12;and $3,%r12;.skip_phase_change:cmp $0,%r12;je .phase0;cmp $1,%r12;je .phase1;cmp $2,%r12;je .phase2;jmp .phase3;.phase0:vaddps %ymm0,%ymm1,%ymm2;vmulps %ymm2,%ymm3,%ymm4;vdivps %ymm4,%ymm5,%ymm6;vaddps %ymm6,%ymm7,%ymm0;vaddps %ymm0,%ymm1,%ymm2;vmulps %ymm2,%ymm3,%ymm4;vdivps %ymm4,%ymm5,%ymm6;vaddps %ymm6,%ymm7,%ymm1;jmp .continue;.phase1:imul %rax,%rbx;add %rbx,%rcx;xor %rcx,%rdx;ror $11,%rax;imul %rdx,%rax;add %rax,%rbx;xor %rbx,%rcx;ror $13,%rdx;imul %rcx,%rdx;jmp .continue;.phase2:test $1,%r14;jz .bp1;test $2,%r14;jnz .bp2;test $4,%r14;jz .bp3;test $8,%r14;jnz .bp4;jmp .branch_done;.bp1:add $1,%rax;jmp .branch_done;.bp2:sub $1,%rbx;jmp .branch_done;.bp3:xor $0xFF,%rcx;jmp .branch_done;.bp4:rol $1,%rdx;.branch_done:jmp .continue;.phase3:push %rax;push %rbx;push %rcx;push %rdx;add (%rsp),%rax;xor 8(%rsp),%rbx;sub 16(%rsp),%rcx;pop %rdx;pop %rcx;pop %rbx;pop %rax;.continue:test $0xFFFFF,%r14;jnz .main_loop;cmp %r13,%r14;jl .main_loop;.exit:mov $60,%rax;xor %rdi,%rdi;syscall
DEFAULT_SPEC_HAVOC_EOF
    log_message "[INFO] Created a default $HAVOC_S_FILE as it was missing. Please use your own if intended."
fi

log_message "[*] Assembling and linking $HAVOC_S_FILE to $HAVOC_EXE..."
as "$HAVOC_S_FILE" -o "$HAVOC_O_FILE" && ld "$HAVOC_O_FILE" -o "$HAVOC_EXE" || {
    log_message "[ERROR] Spec Havoc assembly/linking failed!"
    rm -f "$HAVOC_O_FILE"
    exit 1
}
log_message "[+] Spec Havoc compilation successful: $HAVOC_EXE"
rm -f "$HAVOC_O_FILE" # Clean up object file

echo "timestamp_utc,timestamp_epoch_s,phase,temp_c,freq_khz" > "$HAVOC_DATA_CSV"

# Baseline
temp_c=$(get_cpu_temp_c); freq_khz=$(get_cpu_freq_khz)
log_message "  Baseline: Temp=${temp_c}C, Freq=${freq_khz}KHz"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),baseline,${temp_c},${freq_khz}" >> "$HAVOC_DATA_CSV"
sleep $MONITOR_INTERVAL_S

# Run Spec Havoc
log_message "[*] Starting Spec Havoc test (${HAVOC_DURATION_S}s)..."
( timeout "$HAVOC_DURATION_S"s "$HAVOC_EXE" &>/dev/null ) &
havoc_pid=$!

current_loop_time=0
while [ "$current_loop_time" -lt "$HAVOC_DURATION_S" ]; do
    if ! ps -p "$havoc_pid" > /dev/null; then
        log_message "  Spec Havoc process $havoc_pid ended earlier than expected."
        break
    fi
    temp_c=$(get_cpu_temp_c); freq_khz=$(get_cpu_freq_khz)
    log_message "  Havoc Stress ($((current_loop_time+MONITOR_INTERVAL_S))s/${HAVOC_DURATION_S}s): Temp=${temp_c}C, Freq=${freq_khz}KHz"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),havoc_stress,${temp_c},${freq_khz}" >> "$HAVOC_DATA_CSV"
    sleep $MONITOR_INTERVAL_S
    current_loop_time=$((current_loop_time + MONITOR_INTERVAL_S))
done
wait "$havoc_pid" 2>/dev/null || true # Ensure it's finished if timeout didn't kill it or it finished early
log_message "Spec Havoc stress phase complete."

# Recovery
log_message "[*] Spec Havoc finished. Monitoring recovery..."
temp_c=$(get_cpu_temp_c); freq_khz=$(get_cpu_freq_khz)
log_message "  Post-Havoc: Temp=${temp_c}C, Freq=${freq_khz}KHz"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),post_havoc,${temp_c},${freq_khz}" >> "$HAVOC_DATA_CSV"
sleep $MONITOR_INTERVAL_S # One last recovery datapoint
temp_c=$(get_cpu_temp_c); freq_khz=$(get_cpu_freq_khz)
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),recovery,${temp_c},${freq_khz}" >> "$HAVOC_DATA_CSV"

log_message "[*] Spec Havoc Test Finished. Data in $HAVOC_DATA_CSV. Log in $LOGFILE."
rm -f "$HAVOC_EXE"
sudo chown -R blue:blue .
exit 0