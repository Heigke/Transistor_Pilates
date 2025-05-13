#!/bin/bash

# ─────────────────────────────────────────────────────────────
# Advanced NS-RAM System-Level Analogy Stress Suite v2.2
# !!! EXTREME DANGER - CONCEPTUAL ANALOGY ONLY - FOR TEST MACHINES !!!
#
# Maps NS-RAM transistor dynamics to system behaviors:
# - Neuron mode: Leaky Integrate & Fire (LIF)
# - Synapse modes: Short & Long-Term Plasticity (STP/LTP)
#
# Enhanced with more granular metrics (PMCs, MBW, ECC) and
# configurable custom stress tools.
# Based on concepts from Nature (Vol 640, pp. 69-76)
# ─────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Please run as root or with sudo." >&2
    exit 1
fi

set -euo pipefail

# --- Tool Functions ---
log_install() {
    echo "[+] Installing missing packages: $*"
}

REQUIRED_PACKAGES=(
    stress-ng
    sysbench
    lm-sensors
    linux-tools-common # Provides 'perf'
    "linux-tools-$(uname -r)" # Kernel-specific tools, also for 'perf'
    gcc
    binutils
    build-essential
    powercap-utils
    coreutils
    bc
    python3-pip
    python3-matplotlib
    python3-pandas
    python3-numpy
    mbw         # For memory bandwidth
    edac-utils  # For ECC error reporting
)

# Package manager detection and installation
if command -v apt-get &>/dev/null; then
    apt-get update
    # Install perf separately to ensure it's there before linux-tools-$(uname -r) if that's an issue
    if ! command -v perf &>/dev/null; then
        log_install "linux-tools-common or equivalent for perf"
        apt-get install -y linux-tools-common linux-tools-generic || echo "Perf installation might require specific linux-tools package for your kernel. Please ensure it's installed."
    fi
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        # Skip linux-tools-$(uname -r) if uname -r is empty or problematic
        if [ "$pkg" == "linux-tools-$(uname -r)" ] && [ -z "$(uname -r)" ]; then
            log_message "[WARN] uname -r is empty, skipping installation of kernel-specific linux-tools."
            continue
        fi
        if ! dpkg -s "$pkg" &>/dev/null; then
            log_install "$pkg"
            apt-get install -y "$pkg" || echo "[WARN] Failed to install $pkg, continuing. Some features might not work."
        fi
    done
    # Try installing cpupower separately
    if ! command -v cpupower &>/dev/null; then
        log_install "cpupower"
        apt-get install -y cpupower || apt-get install -y linux-tools-generic || echo "[WARN] Failed to install cpupower, continuing."
    fi
    # Configure sensors
    if command -v sensors-detect &>/dev/null; then
        echo "[*] Running sensors-detect (auto-confirm)..."
        yes | sensors-detect >/dev/null 2>&1 || true
    else
        log_message "[WARN] sensors-detect not found. Temperature readings might not be available."
    fi
else
    echo "[ERROR] Unsupported package manager. Please manually install required packages:" >&2
    printf "  %s\n" "${REQUIRED_PACKAGES[@]}"
    exit 1
fi


# --- Configuration ---
MODE="ALL"               # Options: "ALL", "NEURON", "SYNAPSE_SHORT", "SYNAPSE_LONG"
TOTAL_DURATION_S=300     # Maximum duration for test modes (increased for more metrics)
LOGFILE="nsram_analogy_results_$(date +%Y%m%d_%H%M%S).log"
TEST_DATA_FILE="stress_test_data.bin"
DATA_SIZE_MB=25 # Slightly increased for mbw

# --- Data Collection for Plotting ---
RUN_ID=$(date +%Y%m%d_%H%M%S)
DATA_DIR="stress_data_${RUN_ID}"
mkdir -p "$DATA_DIR"
TEMP_PERF_FILE="${DATA_DIR}/temp_perf_output.txt" # For perf stat output

# CSV data files for plotting - Extended Headers
NEURON_DATA="${DATA_DIR}/neuron_data.csv"
SYNAPTIC_SHORT_DATA="${DATA_DIR}/synaptic_short_data.csv"
SYNAPTIC_LONG_DATA="${DATA_DIR}/synaptic_long_data.csv"
SYSTEM_SUMMARY="${DATA_DIR}/system_summary.csv"

# Initialize data files with new headers
# Neuron data: added PMCs, MBW, ECC
echo "timestamp,cycle,phase,temp,freq,recovery_time,error_detected,ipc,l1d_misses_pmc,llc_misses_pmc,branch_misses_pmc,mbw_score_mbps,ecc_ce_count,ecc_ue_count" > "$NEURON_DATA"
# Synaptic short data: added PMCs, MBW, ECC
echo "timestamp,cycle,phase,pulse_or_elapsed,bench_score,percent_of_baseline,ipc,l1d_misses_pmc,llc_misses_pmc,branch_misses_pmc,mbw_score_mbps,ecc_ce_count,ecc_ue_count" > "$SYNAPTIC_SHORT_DATA"
# Synaptic long data: added PMCs, MBW, ECC
echo "timestamp,cycle,phase,temp,bench_score,error_detected,corruption_detected,ipc,l1d_misses_pmc,llc_misses_pmc,branch_misses_pmc,mbw_score_mbps,ecc_ce_count,ecc_ue_count" > "$SYNAPTIC_LONG_DATA"
# System summary: added PMCs, MBW, ECC (baseline vs final)
echo "metric,baseline,final,percent_change" > "$SYSTEM_SUMMARY"
# Baseline PMCs will be stored separately or as first entry in relevant files.

# --- NS-RAM Analog Parameters ---
# ** Neuron Mode Parameters (LIF model analogy) **
NEURON_PULSE_AMPLITUDE="max"
NEURON_PULSE_INTERVAL_ON_S=5
NEURON_PULSE_INTERVAL_OFF_S=5
NEURON_CYCLES=5 # Reduced for quicker testing with more metrics

# ** Synapse Short-Term Plasticity Parameters **
SYN_ST_POTENTIATION_LOAD="high"
SYN_ST_DEPRESSION_LOAD="idle"
SYN_ST_PULSE_DURATION_S=3
SYN_ST_POT_PULSES=3 # Reduced
SYN_ST_DEP_PULSES=3 # Reduced
SYN_ST_FORGET_DURATION_S=20 # Reduced
SYN_ST_CYCLES=2 # Reduced

# ** Synapse Long-Term Plasticity Parameters **
SYN_LT_POTENTIATION_LOAD="max"
SYN_LT_DEPRESSION_LOAD="idle"
SYN_LT_PULSE_DURATION_S=8 # Reduced
SYN_LT_CYCLES=10 # Reduced
SYN_LT_RETENTION_S=30 # Reduced

# ** Power Limiting (RAPL - Analogy for voltage/current limiting) **
USE_RAPL=false
RAPL_POWER_LIMIT_W=50

# ** Memory Hammer Parameters (Row hammer analog) **
HAMMER_ITERATIONS=2000000 # Reduced for quicker testing
HAMMER_PATTERN_LENGTH=4
HAMMER_WRITE_OPS=1
HAMMER_THREAD_COUNT=2
# New Hammer Configs
HAMMER_ACCESS_PATTERN="seq" # Options: seq, rand, stride, victim_aggressor (victim_aggressor is conceptual for C code)
HAMMER_CACHE_FLUSH="lines"  # Options: none, lines, all

# --- Stress Level Definitions ---
declare -A STRESS_PARAMS
STRESS_PARAMS["max"]="--cpu $(nproc) --matrix $(nproc) --vm $(nproc) --vm-bytes 1G --cpu-method all"
STRESS_PARAMS["high"]="--cpu $(nproc) --matrix 0 --vm $(nproc) --vm-bytes 512M --cpu-method int64,float"
STRESS_PARAMS["medium"]="--cpu $(($(nproc)/2)) --matrix 0 --vm 0 --cpu-method bitops"
STRESS_PARAMS["low"]="--cpu 1 --vm 0 --cpu-method trivial"
STRESS_PARAMS["idle"]=""

# --- Global Variables ---
baseline_freq=0
baseline_temp=0
baseline_bench_score=0
baseline_ipc="N/A"
baseline_l1d_misses="N/A"
baseline_llc_misses="N/A"
baseline_branch_misses="N/A"
baseline_mbw_score="N/A"
baseline_ecc_ce="N/A"
baseline_ecc_ue="N/A"

current_bench_score=0
current_ipc="N/A"
current_l1d_misses="N/A"
current_llc_misses="N/A"
current_branch_misses="N/A"
current_mbw_score="N/A"
current_ecc_ce="N/A"
current_ecc_ue="N/A"

cpu_model=""
final_freq=0
final_temp=0
final_bench_score=0
final_ipc="N/A"
final_l1d_misses="N/A"
final_llc_misses="N/A"
final_branch_misses="N/A"
final_mbw_score="N/A"
final_ecc_ce="N/A"
final_ecc_ue="N/A"

# --- Helper Functions ---
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Function to parse perf stat output (attempts CSV, falls back to grep)
# Returns string: "ipc_val,l1d_misses_val,llc_misses_val,branch_misses_val"
parse_perf_output() {
    local perf_file="$1"
    local ipc="N/A"
    local l1d_misses="N/A"
    local llc_misses="N/A"
    local branch_misses="N/A"

    if [ ! -f "$perf_file" ]; then
        echo "N/A,N/A,N/A,N/A"
        return
    fi

    # Try to parse CSV output first (more robust)
    # Assuming format: value,unit,event,runtime,percentage
    if grep -q 'task-clock' "$perf_file" && grep -q 'instructions' "$perf_file" && grep -q ',' "$perf_file"; then
        local instructions_val=$(grep ',instructions' "$perf_file" | head -n1 | cut -d, -f1 | tr -d '[:space:]')
        local cycles_val=$(grep ',cycles' "$perf_file" | head -n1 | cut -d, -f1 | tr -d '[:space:]')
        if [[ "$instructions_val" =~ ^[0-9]+$ && "$cycles_val" =~ ^[0-9]+$ && "$cycles_val" -ne 0 ]]; then
            ipc=$(echo "scale=2; $instructions_val / $cycles_val" | bc)
        fi
        l1d_misses=$(grep ',L1-dcache-load-misses' "$perf_file" | head -n1 | cut -d, -f1 | tr -d '[:space:]' || echo "N/A")
        llc_misses=$(grep ',LLC-load-misses' "$perf_file" | head -n1 | cut -d, -f1 | tr -d '[:space:]' || echo "N/A")
        branch_misses=$(grep ',branch-misses' "$perf_file" | head -n1 | cut -d, -f1 | tr -d '[:space:]' || echo "N/A")
    else # Fallback to less robust grep/awk for space-separated output
        local instructions_val=$(grep -E '[0-9,]+[[:space:]]+instructions' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g')
        local cycles_val=$(grep -E '[0-9,]+[[:space:]]+cycles' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g')
         if [[ "$instructions_val" =~ ^[0-9]+$ && "$cycles_val" =~ ^[0-9]+$ && "$cycles_val" -ne 0 ]]; then
            ipc=$(echo "scale=2; $instructions_val / $cycles_val" | bc)
        fi
        l1d_misses=$(grep -E '[0-9,]+[[:space:]]+L1-dcache-load-misses' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g' || echo "N/A")
        llc_misses=$(grep -E '[0-9,]+[[:space:]]+LLC-load-misses' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g' || echo "N/A")
        branch_misses=$(grep -E '[0-9,]+[[:space:]]+branch-misses' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g' || echo "N/A")
    fi
    
    # Sanitize N/A
    [ -z "$ipc" ] && ipc="N/A"; [ "$ipc" == "." ] && ipc="N/A"
    [ -z "$l1d_misses" ] && l1d_misses="N/A"
    [ -z "$llc_misses" ] && llc_misses="N/A"
    [ -z "$branch_misses" ] && branch_misses="N/A"

    echo "${ipc:-N/A},${l1d_misses:-N/A},${llc_misses:-N/A},${branch_misses:-N/A}"
}


# Data saving functions - Extended
save_neuron_data() {
    local timestamp=$(date +%s)
    local cycle=$1 phase=$2 temp=$3 freq=$4 recovery_time=$5 error_detected=$6
    local ipc_val=$7 l1d_val=$8 llc_val=$9 branch_val=${10}
    local mbw_val=${11} ecc_ce=${12} ecc_ue=${13}
    echo "$timestamp,$cycle,$phase,$temp,$freq,$recovery_time,$error_detected,$ipc_val,$l1d_val,$llc_val,$branch_val,$mbw_val,$ecc_ce,$ecc_ue" >> "$NEURON_DATA"
}

save_synaptic_short_data() {
    local timestamp=$(date +%s)
    local cycle=$1 phase=$2 pulse_or_elapsed=$3 bench_score=$4
    local ipc_val=$5 l1d_val=$6 llc_val=$7 branch_val=$8
    local mbw_val=$9 ecc_ce=${10} ecc_ue=${11}
    local percent_baseline="N/A"
    if [[ "$bench_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" != "0" && "$baseline_bench_score" != "N/A" ]]; then
        percent_baseline=$(echo "scale=2; 100 * $bench_score / $baseline_bench_score" | bc)
    fi
    echo "$timestamp,$cycle,$phase,$pulse_or_elapsed,$bench_score,$percent_baseline,$ipc_val,$l1d_val,$llc_val,$branch_val,$mbw_val,$ecc_ce,$ecc_ue" >> "$SYNAPTIC_SHORT_DATA"
}

save_synaptic_long_data() {
    local timestamp=$(date +%s)
    local cycle=$1 phase=$2 temp=$3 bench_score=$4 error_detected=$5 corruption_detected=$6
    local ipc_val=$7 l1d_val=$8 llc_val=$9 branch_val=${10}
    local mbw_val=${11} ecc_ce=${12} ecc_ue=${13}
    echo "$timestamp,$cycle,$phase,$temp,$bench_score,$error_detected,$corruption_detected,$ipc_val,$l1d_val,$llc_val,$branch_val,$mbw_val,$ecc_ce,$ecc_ue" >> "$SYNAPTIC_LONG_DATA"
}

save_system_summary_metric() {
    local metric_name="$1"
    local base_val="$2"
    local final_val="$3"
    local percent_change="N/A"

    if [[ "$base_val" =~ ^[0-9]+(\.[0-9]+)?$ && "$final_val" =~ ^[0-9]+(\.[0-9]+)?$ && "$base_val" != "0" && "$base_val" != "N/A" ]]; then
        percent_change=$(echo "scale=2; 100 * ($final_val - $base_val) / $base_val" | bc)
    fi
    echo "$metric_name,$base_val,$final_val,$percent_change" >> "$SYSTEM_SUMMARY"
}

save_system_summary() {
    log_message "Saving system summary..."
    save_system_summary_metric "frequency_khz" "$baseline_freq" "$final_freq"
    save_system_summary_metric "temperature_c" "$baseline_temp" "$final_temp"
    save_system_summary_metric "sysbench_score" "$baseline_bench_score" "$final_bench_score"
    save_system_summary_metric "ipc" "$baseline_ipc" "$final_ipc"
    save_system_summary_metric "l1d_misses" "$baseline_l1d_misses" "$final_l1d_misses"
    save_system_summary_metric "llc_misses" "$baseline_llc_misses" "$final_llc_misses"
    save_system_summary_metric "branch_misses" "$baseline_branch_misses" "$final_branch_misses"
    save_system_summary_metric "mbw_score_mbps" "$baseline_mbw_score" "$final_mbw_score"
    save_system_summary_metric "ecc_ce_total" "$baseline_ecc_ce" "$final_ecc_ce" # Assuming these are cumulative if not reset
    save_system_summary_metric "ecc_ue_total" "$baseline_ecc_ue" "$final_ecc_ue"
}


get_cpu_freq() {
    lscpu -p=CPU,MHZ | grep -E '^[0-9]+,' | head -n1 | awk -F, '{ printf "%.0f000", $2 }' 2>/dev/null || \
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A"
}

get_cpu_temp() {
    local temp_val="N/A"
    if command -v sensors &>/dev/null; then
        temp_val=$(sensors 2>/dev/null | grep -iE 'Package id 0:|Core 0:|temp1:' | head -n1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^\+[0-9]+\.[0-9]+°C$/) {sub(/^\+/,"",$i); sub(/°C$/,"",$i); print $i; exit}}')
    fi
     [ -z "$temp_val" ] || [[ ! "$temp_val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && temp_val="N/A"
    echo "$temp_val"
}

# Function to run sysbench and perf, returns sysbench score, sets global current_pmc_values
run_perf_and_sysbench() {
    log_message "  Running sysbench CPU benchmark with perf..."
    local sysbench_score="N/A"
    # Define PMC events to monitor
    # Common events: cycles, instructions, cache-references, cache-misses, L1-dcache-load-misses, LLC-load-misses, branch-instructions, branch-misses
    # The specific event names might vary slightly between CPU architectures.
    # Using generic event names that perf usually understands.
    local perf_events="cycles,instructions,L1-dcache-load-misses,LLC-load-misses,branch-misses"
    
    # Clear previous temp perf file
    rm -f "$TEMP_PERF_FILE"

    # Attempt to use CSV output from perf stat if available
    if perf stat -x, -e "$perf_events" --log-fd 1 sleep 0.1 &>/dev/null; then
        log_message "    Using perf stat with CSV output."
        perf stat -x, -e "$perf_events" -o "$TEMP_PERF_FILE" --append -- sysbench cpu --cpu-max-prime=15000 --threads="$(nproc)" run &>/dev/null
    else
        log_message "    Perf stat CSV output not available or failed, falling back to standard output parsing."
        perf stat    -e "$perf_events" -o "$TEMP_PERF_FILE" --append -- sysbench cpu --cpu-max-prime=15000 --threads="$(nproc)" run &>/dev/null
    fi
    
    # Get sysbench score separately as perf might interfere with its stdout
    sysbench_score=$(sysbench cpu --cpu-max-prime=15000 --threads="$(nproc)" run 2>/dev/null | grep 'events per second:' | awk '{print $4}' | tr -d '\r\n')
    if [[ ! "$sysbench_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "    WARN: Sysbench failed to produce valid score."
        sysbench_score="N/A"
    else
        log_message "    Sysbench score: $sysbench_score events/sec"
    fi

    # Parse the perf output file
    local pmc_results_str=$(parse_perf_output "$TEMP_PERF_FILE")
    # Update global current PMC values
    current_ipc=$(echo "$pmc_results_str" | cut -d, -f1)
    current_l1d_misses=$(echo "$pmc_results_str" | cut -d, -f2)
    current_llc_misses=$(echo "$pmc_results_str" | cut -d, -f3)
    current_branch_misses=$(echo "$pmc_results_str" | cut -d, -f4)

    log_message "    Perf Metrics: IPC=${current_ipc}, L1D Misses=${current_l1d_misses}, LLC Misses=${current_llc_misses}, Branch Misses=${current_branch_misses}"
    
    printf "%s" "$sysbench_score" # Return sysbench score for assignment
}

run_mbw() {
    log_message "  Running mbw memory benchmark..."
    current_mbw_score="N/A" # Reset before run
    if command -v mbw &>/dev/null; then
        local mbw_raw_output
        # Run mbw with a reasonable size and iterations, capturing stderr for parsing
        # Using fixed block size of 256MB as an example, adjust if needed
        mbw_raw_output=$(mbw -q -n 500 256 2>&1) 
        
        # Try to parse the average for 'MEMCPY' or 'DUMB' as a fallback
        current_mbw_score=$(echo "$mbw_raw_output" | grep -iE 'AVG.*MEMCPY' | awk '{print $3}' | head -n1)
        if [[ ! "$current_mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            current_mbw_score=$(echo "$mbw_raw_output" | grep -iE 'AVG.*DUMB' | awk '{print $3}' | head -n1)
        fi

        if [[ ! "$current_mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_message "    WARN: Failed to parse mbw output. Raw: $mbw_raw_output"
            current_mbw_score="N/A"
        else
            log_message "    MBW Score (AVG MEMCPY/DUMB): ${current_mbw_score} MB/s"
        fi
    else
        log_message "    WARN: mbw not found. Skipping memory bandwidth test."
    fi
    printf "%s" "$current_mbw_score"
}

get_ecc_errors() {
    log_message "  Checking ECC errors..."
    current_ecc_ce="N/A"; current_ecc_ue="N/A" # Reset
    if command -v edac-ctl &>/dev/null; then
        if edac-ctl --status &>/dev/null; then # Check if EDAC modules are loaded
            current_ecc_ce=$(edac-ctl --error_count | grep 'Corrected:' | awk '{print $2}' || echo "0")
            current_ecc_ue=$(edac-ctl --error_count | grep 'Uncorrected:' | awk '{print $2}' || echo "0")
            log_message "    ECC Errors: Corrected=${current_ecc_ce:-0}, Uncorrected=${current_ecc_ue:-0}"
        else
            log_message "    WARN: EDAC kernel modules not loaded or no errors reported by edac-ctl. Skipping ECC check."
        fi
    else
        log_message "    WARN: edac-utils not found. Skipping ECC check."
    fi
    # These are typically cumulative counts, so the script logs the current totals.
    # For "new" errors in a phase, one would need to diff with previous values.
    # For simplicity here, we log the current totals.
    printf "%s,%s" "${current_ecc_ce:-N/A}" "${current_ecc_ue:-N/A}"
}


apply_stress() {
    local level=$1
    local duration_s=$2
    local stress_cmd="${STRESS_PARAMS[$level]}"

    if [ -z "$stress_cmd" ] || [ "$level" == "idle" ]; then
        log_message "  Applying IDLE state for ${duration_s}s."
        sleep "$duration_s"
        return
    fi

    log_message "  Applying stress level '$level' for ${duration_s}s: $stress_cmd"
    stress-ng $stress_cmd --timeout "${duration_s}s" --metrics-brief --log-brief &> /dev/null &
    local stress_pid=$!
    
    # Monitor temperature and frequency during stress if needed (complex to do accurately in parallel in bash)
    # For now, metrics are taken before and after the main stress period.
    
    # Wait for the specified duration (stress-ng also has a timeout)
    local waited_time=0
    while [ $waited_time -lt "$duration_s" ]; do
        sleep 1
        # Check if stress_pid is still running
        if ! ps -p $stress_pid > /dev/null; then
            log_message "    stress-ng process $stress_pid finished early or was killed."
            break
        fi
        waited_time=$((waited_time + 1))
    done
    
    # Ensure it's stopped if sleep finishes first or if it's still running
    if ps -p $stress_pid > /dev/null; then
        log_message "    Timeout reached for stress level '$level', ensuring process $stress_pid is stopped."
        kill $stress_pid 2>/dev/null || true 
    fi
    wait $stress_pid 2>/dev/null || true # Collect exit status, suppress errors
    log_message "  Stress level '$level' application finished."
}


set_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Setting RAPL power limit to ${RAPL_POWER_LIMIT_W}W..."
        powercap-set -p intel-rapl -z 0 -c 0 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 0 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        log_message "    WARN: Failed to set RAPL package-0 long term limit."
        
        powercap-set -p intel-rapl -z 0 -c 1 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 1 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        log_message "    WARN: Failed to set RAPL package-0 short term limit (continuing)."
    elif [ "$USE_RAPL" = true ]; then
        log_message "    WARN: USE_RAPL is true, but powercap-set command not found."
    fi
}

reset_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Resetting RAPL power limit to default (high value)..."
        local high_limit_uw=$((250 * 1000000)) # 250W as a high/default value
        powercap-set -p intel-rapl -z 0 -c 0 -l "$high_limit_uw" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 0 -l "$high_limit_uw" --quiet || \
        log_message "    WARN: Failed to reset RAPL package-0 long term limit."

        powercap-set -p intel-rapl -z 0 -c 1 -l "$high_limit_uw" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 1 -l "$high_limit_uw" --quiet || \
        log_message "    WARN: Failed to reset RAPL package-0 short term limit (continuing)."
    fi
}

# --- Cleanup Function ---
cleanup() {
  log_message "[*] Cleaning up processes and files..."
  # Kill all children of this script's process group
  # This is safer than pkill -P $$ if sub-shells create their own process groups
  if [ -n "$BASHPID" ]; then # BASHPID is more reliable than $$ in some contexts
      PGID=$(ps -o pgid= -p "$BASHPID" | grep -o '[0-9]*')
      if [ -n "$PGID" ]; then
          kill -- "-$PGID" 2>/dev/null || true # Send SIGTERM to the process group
      fi
  else # Fallback for shells that don't define BASHPID
      pkill -P $$ 2>/dev/null || true
  fi
  wait 2>/dev/null || true


  log_message "[*] Resetting system state..."
  reset_rapl_limit
  if command -v cpupower &> /dev/null; then
      log_message "  Attempting to set CPU governor to powersave..."
      cpupower frequency-set -g powersave || log_message "    WARN: Failed to set powersave governor."
  fi
  if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
      log_message "  Attempting to re-enable Intel P-state turbo..."
      echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo || log_message "    WARN: Failed to re-enable turbo (intel_pstate)."
  elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
      log_message "  Attempting to re-enable CPU frequency boost..."
      echo 1 > /sys/devices/system/cpu/cpufreq/boost || log_message "    WARN: Failed to re-enable boost (cpufreq)."
  fi
  if [ -f /proc/sys/kernel/randomize_va_space ]; then
      log_message "  Attempting to reset ASLR to default..."
      echo 2 > /proc/sys/kernel/randomize_va_space || log_message "    WARN: Failed to reset ASLR."
  fi

  rm -f hammer hammer.c spec_havoc spec_havoc.o spec_havoc.S "$TEST_DATA_FILE" "$TEMP_PERF_FILE" 2>/dev/null || true
  log_message "[*] Cleanup finished."
}
trap cleanup EXIT INT TERM

# --- Compile Custom Stress Tools ---
# Enhanced hammer.c with parameterized access pattern and cache flush
compile_hammer() {
    log_message "[*] Compiling enhanced hammer tool (v2.2)..."
    cat > hammer.c << 'HAMMER_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h> // For _mm_clflush, _mm_mfence, _mm_sfence
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <getopt.h> // For command line argument parsing

// Define access patterns
typedef enum {
    ACCESS_SEQ,
    ACCESS_RAND,
    ACCESS_STRIDE,
    ACCESS_VICTIM_AGGRESSOR // Conceptual, needs specific implementation
} access_pattern_t;

// Define cache flush modes
typedef enum {
    CACHE_FLUSH_NONE,
    CACHE_FLUSH_LINES, // Flush accessed lines
    CACHE_FLUSH_ALL    // Attempt to flush entire cache (difficult, often not truly possible from user space)
} cache_flush_t;

typedef struct {
    size_t reps;
    size_t row_size;
    size_t distance;
    size_t pattern_length;
    uint8_t check_corruption;
    uint8_t perform_write;
    uint8_t verbose;
    size_t thread_count;
    access_pattern_t access_pattern;
    cache_flush_t cache_flush_mode;
    uint32_t random_seed;
} hammer_config_t;

typedef struct {
    void *mem_region;
    size_t mem_region_size;
    size_t offset_in_region; // Offset for this thread's operations within mem_region
    hammer_config_t *config;
    uint8_t *ref_data; // Pointer to the base of the reference data for the entire region
    uint8_t *corruption_detected_flag; // Shared flag among threads
    int thread_id;
} hammer_thread_data_t;

uint64_t get_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Simple pseudo-random number generator (for rand access pattern)
uint32_t prng_state;
void init_prng(uint32_t seed) {
    prng_state = seed;
}
uint32_t simple_rand() {
    prng_state = (1103515245 * prng_state + 12345) & 0x7FFFFFFF;
    return prng_state;
}


void *hammer_thread(void *arg) {
    hammer_thread_data_t *data = (hammer_thread_data_t *)arg;
    hammer_config_t *cfg = data->config;

    volatile uint8_t *base_addr = (uint8_t *)data->mem_region + data->offset_in_region;
    size_t current_op_count = 0;

    // For stride and victim/aggressor, more complex address generation is needed.
    // This is a simplified example.
    size_t max_offset = data->mem_region_size - data->offset_in_region - cfg->row_size;
    if (cfg->pattern_length > 0 && cfg->distance > 0) {
         max_offset = cfg->pattern_length * cfg->distance;
         if (max_offset > data->mem_region_size - data->offset_in_region - cfg->row_size) {
            max_offset = data->mem_region_size - data->offset_in_region - cfg->row_size;
         }
    }


    for (size_t i = 0; i < cfg->reps; i++) {
        for (size_t p_idx = 0; p_idx < cfg->pattern_length; ++p_idx) {
            volatile uint64_t *target_addr;
            size_t current_byte_offset = 0;

            switch (cfg->access_pattern) {
                case ACCESS_SEQ:
                    current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1);
                    break;
                case ACCESS_RAND:
                    current_byte_offset = simple_rand() % (max_offset + 1);
                    current_byte_offset -= current_byte_offset % sizeof(uint64_t); // Align to 64-bit
                    break;
                case ACCESS_STRIDE: // Example: stride by distance
                    current_byte_offset = (current_op_count * cfg->distance) % (max_offset + 1);
                    break;
                case ACCESS_VICTIM_AGGRESSOR:
                    // This would require a more complex setup, e.g., two aggressor rows
                    // sandwiching a victim row. For simplicity, falls back to sequential.
                    current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1);
                    break;
                default:
                    current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1);
            }
            target_addr = (volatile uint64_t *)(base_addr + current_byte_offset);

            if (cfg->cache_flush_mode == CACHE_FLUSH_LINES) {
                _mm_clflush((const void *)target_addr);
            }

            if (cfg->perform_write) {
                *target_addr = i + p_idx; // Write operation
            } else {
                volatile uint64_t dummy = *target_addr; // Read operation
                (void)dummy;
            }
            _mm_mfence(); // Memory fence
            current_op_count++;
        }

        if (cfg->cache_flush_mode == CACHE_FLUSH_ALL) {
            // Note: True full cache flush from user space is hard.
            // This is a placeholder; _mm_mfence might be the best we can do generally,
            // or use a large memory sweep if trying to evict.
            _mm_mfence();
        }
         _mm_sfence(); // Store fence after writes

        if (cfg->check_corruption && data->ref_data && !(*data->corruption_detected_flag) && (i % 10000 == 0)) { // Check less frequently
            for (size_t p_idx = 0; p_idx < cfg->pattern_length; ++p_idx) {
                 size_t check_offset = (p_idx * cfg->distance) % (max_offset + 1);
                 // Check first few bytes of the "row" (simplified)
                 for (size_t k=0; k < sizeof(uint64_t) && (data->offset_in_region + check_offset + k) < data->mem_region_size; ++k) {
                    uint8_t expected = data->ref_data[data->offset_in_region + check_offset + k];
                    uint8_t actual = ((uint8_t*)data->mem_region)[data->offset_in_region + check_offset + k];
                    if (cfg->perform_write && expected != actual) { // Only check if we wrote
                        // This check is tricky because we are writing 'i+p_idx'.
                        // A proper check would re-initialize ref_data or compare against expected write values.
                        // For simplicity, if perform_write is on, this check is less meaningful with current write pattern.
                        // If perform_write is OFF, then ref_data should match.
                    } else if (!cfg->perform_write && expected != actual) {
                         *data->corruption_detected_flag = 1;
                         if(cfg->verbose) printf("[Thread %d] Corruption at mem_offset %p (expected %02x, got %02x)\n",
                               data->thread_id,
                               (void*)(base_addr + check_offset + k),
                               expected, actual);
                        goto end_thread_loop; // Exit if corruption found
                    }
                 }
            }
        }
    }
end_thread_loop:
    return NULL;
}

void print_usage(char *argv0) {
    printf("NSR-AM Memory Hammer v2.2 - System-Level Analogy for Transistor Stress\n");
    printf("Usage: %s [options]\n", argv0);
    printf("Options:\n");
    printf("  --reps N              Hammering iterations (Default: 20M)\n");
    printf("  --row-size N          Memory row size (page size, Default: 4096)\n");
    printf("  --distance N          Distance between addresses (Default: 8192)\n");
    printf("  --pattern-length N    Access pattern length (Default: 4)\n");
    printf("  --check-corruption N  Check for memory corruption 0/1 (Default: 1, only effective if --perform-write=0)\n");
    printf("  --perform-write N     Perform write operations 0/1 (Default: 1)\n");
    printf("  --thread-count N      Number of parallel threads (Default: 2)\n");
    printf("  --access-pattern STR  Access pattern: seq, rand, stride, victim (Default: seq)\n");
    printf("  --cache-flush STR     Cache flush: none, lines, all (Default: lines)\n");
    printf("  --seed N              Random seed for 'rand' pattern (Default: current time)\n");
    printf("  --verbose N           Verbose output 0/1 (Default: 1)\n");
    printf("  --help                Show this help\n");
}


int main(int argc, char *argv[]) {
    hammer_config_t config = {
        .reps = 2000000, .row_size = 4096, .distance = 8192, .pattern_length = 4,
        .check_corruption = 1, .perform_write = 1, .verbose = 1, .thread_count = 2,
        .access_pattern = ACCESS_SEQ, .cache_flush_mode = CACHE_FLUSH_LINES, .random_seed = (uint32_t)time(NULL)
    };

    static struct option long_options[] = {
        {"reps", required_argument, 0, 'r'}, {"row-size", required_argument, 0, 's'},
        {"distance", required_argument, 0, 'd'}, {"pattern-length", required_argument, 0, 'l'},
        {"check-corruption", required_argument, 0, 'c'}, {"perform-write", required_argument, 0, 'w'},
        {"thread-count", required_argument, 0, 't'}, {"access-pattern", required_argument, 0, 'a'},
        {"cache-flush", required_argument, 0, 'f'}, {"seed", required_argument, 0, 'e'},
        {"verbose", required_argument, 0, 'v'}, {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "r:s:d:l:c:w:t:a:f:e:v:h", long_options, NULL)) != -1) {
        switch (opt) {
            case 'r': config.reps = atoll(optarg); break;
            case 's': config.row_size = atoll(optarg); break;
            case 'd': config.distance = atoll(optarg); break;
            case 'l': config.pattern_length = atoll(optarg); break;
            case 'c': config.check_corruption = atoi(optarg); break;
            case 'w': config.perform_write = atoi(optarg); break;
            case 't': config.thread_count = atoi(optarg); break;
            case 'a':
                if (strcmp(optarg, "seq") == 0) config.access_pattern = ACCESS_SEQ;
                else if (strcmp(optarg, "rand") == 0) config.access_pattern = ACCESS_RAND;
                else if (strcmp(optarg, "stride") == 0) config.access_pattern = ACCESS_STRIDE;
                else if (strcmp(optarg, "victim") == 0) config.access_pattern = ACCESS_VICTIM_AGGRESSOR;
                else { fprintf(stderr, "Invalid access pattern: %s\n", optarg); return 1; }
                break;
            case 'f':
                if (strcmp(optarg, "none") == 0) config.cache_flush_mode = CACHE_FLUSH_NONE;
                else if (strcmp(optarg, "lines") == 0) config.cache_flush_mode = CACHE_FLUSH_LINES;
                else if (strcmp(optarg, "all") == 0) config.cache_flush_mode = CACHE_FLUSH_ALL;
                else { fprintf(stderr, "Invalid cache flush mode: %s\n", optarg); return 1; }
                break;
            case 'e': config.random_seed = atoi(optarg); break;
            case 'v': config.verbose = atoi(optarg); break;
            case 'h': print_usage(argv[0]); return 0;
            default: print_usage(argv[0]); return 1;
        }
    }
    init_prng(config.random_seed);


    size_t total_mem_size = config.row_size * config.pattern_length * config.thread_count * 2; // Ensure enough space
    if (total_mem_size == 0) total_mem_size = config.row_size * 10; // Min size

    void *mem_region = aligned_alloc(config.row_size, total_mem_size);
    if (!mem_region) { perror("Memory allocation failed"); return 1; }
    memset(mem_region, 0, total_mem_size); // Initialize

    uint8_t *ref_data_copy = NULL;
    if (config.check_corruption && !config.perform_write) { // Corruption check is most meaningful if not writing
        ref_data_copy = malloc(total_mem_size);
        if (!ref_data_copy) { perror("Ref data allocation failed"); free(mem_region); return 1; }
        for(size_t i=0; i < total_mem_size; ++i) ref_data_copy[i] = ((i * 37) + (i % 13)) & 0xFF; // Fill with a pattern
        memcpy(mem_region, ref_data_copy, total_mem_size);
    } else if (config.check_corruption && config.perform_write) {
        if(config.verbose) printf("WARN: Corruption check with perform_write=1 is complex and may not be accurate with this tool's simple check.\n");
    }


    if (config.verbose) {
        printf("NS-RAM Memory Hammer v2.2\nConfig: Reps=%zuM, PatternLen=%zu, WriteOps=%d, Threads=%zu, Access=%d, Flush=%d, Seed=%u, Mem=%zuMB\n",
               config.reps / 1000000, config.pattern_length, config.perform_write, config.thread_count,
               config.access_pattern, config.cache_flush_mode, config.random_seed, total_mem_size / (1024 * 1024));
    }

    pthread_t *threads = malloc(config.thread_count * sizeof(pthread_t));
    hammer_thread_data_t *thread_data_array = malloc(config.thread_count * sizeof(hammer_thread_data_t));
    uint8_t overall_corruption_detected = 0;

    uint64_t start_ns = get_ns();

    size_t per_thread_mem_span = total_mem_size / config.thread_count;

    for (size_t t = 0; t < config.thread_count; t++) {
        thread_data_array[t].mem_region = mem_region;
        thread_data_array[t].mem_region_size = total_mem_size; // Each thread knows total size
        thread_data_array[t].offset_in_region = t * per_thread_mem_span; // Threads operate on distinct (or overlapping if desired) parts
        thread_data_array[t].config = &config;
        thread_data_array[t].ref_data = ref_data_copy;
        thread_data_array[t].corruption_detected_flag = &overall_corruption_detected;
        thread_data_array[t].thread_id = t;
        pthread_create(&threads[t], NULL, hammer_thread, &thread_data_array[t]);
    }

    for (size_t t = 0; t < config.thread_count; t++) {
        pthread_join(threads[t], NULL);
    }

    uint64_t end_ns = get_ns();
    double elapsed_s = (end_ns - start_ns) / 1000000000.0;

    if (config.verbose) {
        printf("Results: Time=%.2fs, Rate=%.2f M iter/s\n", elapsed_s, (config.reps * config.thread_count) / elapsed_s / 1000000.0);
        if (config.check_corruption && !config.perform_write) { // Only report if meaningful
            printf("  STATUS: %s\n", overall_corruption_detected ? "CORRUPTION DETECTED" : "No corruption detected");
        }
    }

    free(mem_region);
    free(threads);
    free(thread_data_array);
    if (ref_data_copy) free(ref_data_copy);

    return overall_corruption_detected ? 2 : 0; // Return 2 if corruption, 0 otherwise
}
HAMMER_EOF

    # Compile hammer.c
    gcc -O2 -march=native -pthread -o hammer hammer.c -Wall || {
        log_message "!!! Hammer compilation failed!"
        # Try without -march=native if it fails (e.g. in VM without CPU feature exposure)
        log_message "Retrying Hammer compilation without -march=native..."
        gcc -O2 -pthread -o hammer hammer.c -Wall || {
             log_message "!!! Hammer compilation failed (even without -march=native)!"
             return 1
        }
    }
    log_message "[+] Hammer compilation successful."
    return 0
}

compile_spec_havoc() {
    log_message "[*] Compiling enhanced spec_havoc tool (v2.1)..."
    # spec_havoc.S remains largely the same as it's already complex.
    # Parameterization from Bash to assembly is non-trivial without a C wrapper.
    # For now, different "versions" of spec_havoc could be compiled if needed,
    # or a C wrapper could be developed to pass parameters.
    cat > spec_havoc.S << 'SPEC_HAVOC_EOF'
.section .text
.global _start

# NS-RAM Analog: This assembly code stresses different CPU components
# to simulate transistor stress patterns within the NS-RAM architecture.
# The variable instruction mix simulates different voltage/current stresses.

_start:
    # Initialize AVX registers (NS-RAM analog: Initial charge state)
    vmovaps %ymm0, %ymm1; vmovaps %ymm0, %ymm2; vmovaps %ymm0, %ymm3; vmovaps %ymm0, %ymm4
    vmovaps %ymm0, %ymm5; vmovaps %ymm0, %ymm6; vmovaps %ymm0, %ymm7
    
    xor %r12, %r12                # Current phase (0-3)
    mov $200000000, %r13          # Max iterations (reduced for faster runs)
    xor %r14, %r14                # Iteration counter
    
    mov $0x5555555555555555, %rax; mov $0xaaaaaaaaaaaaaaaa, %rbx
    mov $0x3333333333333333, %rcx; mov $0xcccccccccccccccc, %rdx
    
.main_loop:
    inc %r14; cmp %r13, %r14; jge .exit
    test $0x1FFF, %r14; jnz .skip_phase_change
    inc %r12; and $3, %r12
.skip_phase_change:
    cmp $0, %r12; je .phase0; cmp $1, %r12; je .phase1
    cmp $2, %r12; je .phase2; jmp .phase3

.phase0: # FPU/Vector-intense
    vaddps %ymm0, %ymm1, %ymm2; vmulps %ymm2, %ymm3, %ymm4; vdivps %ymm4, %ymm5, %ymm6
    vaddps %ymm6, %ymm7, %ymm0; vaddps %ymm0, %ymm1, %ymm2; vmulps %ymm2, %ymm3, %ymm4
    vdivps %ymm4, %ymm5, %ymm6; vaddps %ymm6, %ymm7, %ymm1; jmp .continue

.phase1: # Integer ALU
    imul %rax, %rbx; add %rbx, %rcx; xor %rcx, %rdx; ror $11, %rax
    imul %rdx, %rax; add %rax, %rbx; xor %rbx, %rcx; ror $13, %rdx; imul %rcx, %rdx; jmp .continue

.phase2: # Branch prediction
    test $1, %r14; jz .bp1; test $2, %r14; jnz .bp2; test $4, %r14; jz .bp3
    test $8, %r14; jnz .bp4; jmp .branch_done
.bp1: add $1, %rax; jmp .branch_done
.bp2: sub $1, %rbx; jmp .branch_done
.bp3: xor $0xFF, %rcx; jmp .branch_done
.bp4: rol $1, %rdx
.branch_done: jmp .continue

.phase3: # Mixed load/store
    push %rax; push %rbx; push %rcx; push %rdx
    add (%rsp), %rax; xor 8(%rsp), %rbx; sub 16(%rsp), %rcx
    pop %rdx; pop %rcx; pop %rbx; pop %rax

.continue:
    test $0xFFFFF, %r14; jnz .main_loop # Check counter periodically
    cmp %r13, %r14; jl .main_loop
.exit:
    mov $60, %rax; xor %rdi, %rdi; syscall
SPEC_HAVOC_EOF

    as spec_havoc.S -o spec_havoc.o && ld spec_havoc.o -o spec_havoc || {
        log_message "!!! Spec Havoc assembly/linking failed!"
        return 1
    }
    log_message "[+] Spec Havoc compilation successful."
    return 0
}

# =============================================================
#               INITIAL SETUP & BASELINE
# =============================================================
log_message "=== Advanced NS-RAM System Analogy Stress Test v2.2 ==="
log_message "Start time: $(date)"
log_message "!!! EXTREME WARNING: DANGEROUS & EXPERIMENTAL SCRIPT !!!"
log_message "Mode: $MODE"
cpu_model=$(lscpu | grep 'Model name' | sed 's/Model name:[[:space:]]*//' || echo "Unknown CPU")
log_message "CPU: $cpu_model"
log_message "Kernel: $(uname -r)"

log_message "[*] Initial system configuration..."
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g performance || log_message "WARN: Failed to set performance governor."
else
    log_message "WARN: cpupower not found, skipping governor setting."
fi

if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo || true
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    echo 0 > /sys/devices/system/cpu/cpufreq/boost || true
else
    log_message "[*] WARN: Could not find standard interface to disable Turbo Boost."
fi
if [ -f /proc/sys/kernel/randomize_va_space ]; then
    echo 0 > /proc/sys/kernel/randomize_va_space || true # Disable ASLR
fi
set_rapl_limit # Apply initial power limit if enabled

log_message "[*] Compiling custom stress tools..."
compile_hammer || log_message "[WARN] Hammer tool compilation failed, some tests might be affected."
compile_spec_havoc || log_message "[WARN] Spec Havoc tool compilation failed, some tests might be affected."

log_message "[1] CAPTURING SYSTEM BASELINE"
sleep 1 # Allow system to settle
baseline_freq=$(get_cpu_freq)
baseline_temp=$(get_cpu_temp)
log_message "  Initial frequency: ${baseline_freq} KHz, Initial temp: ${baseline_temp} C"

log_message "  Running Baseline Performance (Sysbench with Perf)..."
baseline_bench_score=$(run_perf_and_sysbench) # This sets global current_pmc_values
baseline_ipc="$current_ipc"; baseline_l1d_misses="$current_l1d_misses"; baseline_llc_misses="$current_llc_misses"; baseline_branch_misses="$current_branch_misses"
log_message "  Baseline Sysbench CPU Score: ${baseline_bench_score} events/sec"
log_message "  Baseline Perf: IPC=${baseline_ipc}, L1D=${baseline_l1d_misses}, LLC=${baseline_llc_misses}, Branch=${baseline_branch_misses}"

log_message "  Running Baseline Memory Bandwidth (mbw)..."
baseline_mbw_score=$(run_mbw) # This sets global current_mbw_score
log_message "  Baseline MBW Score: ${baseline_mbw_score} MB/s"

log_message "  Getting Baseline ECC Errors..."
ecc_baseline_values=$(get_ecc_errors) # This sets global current_ecc_ce, current_ecc_ue
baseline_ecc_ce="$current_ecc_ce"; baseline_ecc_ue="$current_ecc_ue"
log_message "  Baseline ECC: CE=${baseline_ecc_ce}, UE=${baseline_ecc_ue}"

log_message "[*] Generating test data ($DATA_SIZE_MB MB)..."
dd if=/dev/urandom of="$TEST_DATA_FILE" bs=1M count=$DATA_SIZE_MB status=none conv=fsync
md5_orig=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Original data hash (MD5): $md5_orig"
sync; echo 3 > /proc/sys/vm/drop_caches || true # Drop caches before tests start

# =============================================================
#                    MODE: NEURON (LIF Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "NEURON" ]; then
    log_message "\n[2] NEURON MODE TEST (LIF Analogy)"
    # ... (Neuron mode implementation - collect all metrics)
    failed_integrate=false
    for cycle in $(seq 1 $NEURON_CYCLES); do
        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Applying Pulse (τon)..."
        temp_before_pulse=$(get_cpu_temp)
        
        apply_stress "$NEURON_PULSE_AMPLITUDE" "$NEURON_PULSE_INTERVAL_ON_S" & stress_pid=$!
        if [ -x "./spec_havoc" ]; then
            timeout "${NEURON_PULSE_INTERVAL_ON_S}s" ./spec_havoc &>/dev/null & havoc_pid=$!
        fi
        wait $stress_pid 2>/dev/null; [ -n "${havoc_pid:-}" ] && { kill $havoc_pid 2>/dev/null || true; wait $havoc_pid 2>/dev/null || true; }
        
        temp_after_pulse=$(get_cpu_temp); freq_after_pulse=$(get_cpu_freq)
        # Get PMCs, MBW, ECC after pulse
        local dummy_score=$(run_perf_and_sysbench) # To get PMCs
        local pulse_ipc="$current_ipc"; local pulse_l1d="$current_l1d_misses"; local pulse_llc="$current_llc_misses"; local pulse_branch="$current_branch_misses"
        local pulse_mbw=$(run_mbw)
        local pulse_ecc_values=$(get_ecc_errors); local pulse_ecc_ce="$current_ecc_ce"; local pulse_ecc_ue="$current_ecc_ue"

        log_message "  Pulse End: Temp=${temp_after_pulse}C, Freq=${freq_after_pulse}KHz, IPC=${pulse_ipc}, MBW=${pulse_mbw}"
        error_detected=0; if dmesg | tail -n 50 | grep -q -iE 'MCE|uncorrected|critical|panic'; then error_detected=1; failed_integrate=true; fi
        save_neuron_data "$cycle" "pulse" "$temp_after_pulse" "$freq_after_pulse" "N/A" "$error_detected" \
                         "$pulse_ipc" "$pulse_l1d" "$pulse_llc" "$pulse_branch" "$pulse_mbw" "$pulse_ecc_ce" "$pulse_ecc_ue"
        if [ "$failed_integrate" = true ]; then break; fi

        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Recovery phase (τoff - Leaking)..."
        time_start_recovery=$(date +%s.%N); sleep "$NEURON_PULSE_INTERVAL_OFF_S"; time_end_recovery=$(date +%s.%N)
        
        temp_after_recovery=$(get_cpu_temp); freq_after_recovery=$(get_cpu_freq)
        local recovery_duration=$(echo "$time_end_recovery - $time_start_recovery" | bc)
        # Get PMCs, MBW, ECC after recovery
        dummy_score=$(run_perf_and_sysbench) # To get PMCs
        local rec_ipc="$current_ipc"; local rec_l1d="$current_l1d_misses"; local rec_llc="$current_llc_misses"; local rec_branch="$current_branch_misses"
        local rec_mbw=$(run_mbw)
        local rec_ecc_values=$(get_ecc_errors); local rec_ecc_ce="$current_ecc_ce"; local rec_ecc_ue="$current_ecc_ue"

        log_message "  Recovery End: Temp=${temp_after_recovery}C, Freq=${freq_after_recovery}KHz, IPC=${rec_ipc}, MBW=${rec_mbw}"
        save_neuron_data "$cycle" "recovery" "$temp_after_recovery" "$freq_after_recovery" "$recovery_duration" "0" \
                         "$rec_ipc" "$rec_l1d" "$rec_llc" "$rec_branch" "$rec_mbw" "$rec_ecc_ce" "$rec_ecc_ue"
    done
    log_message "[$(if [ "$failed_integrate" = true ]; then echo "!!! NEURON MODE FAILED"; else echo "✓ NEURON MODE COMPLETED"; fi)]"
fi

# =============================================================
#            MODE: SYNAPSE (Short-Term Plasticity Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_SHORT" ]; then
    log_message "\n[3] SYNAPSE MODE TEST (Short-Term Plasticity Analogy)"
    for cycle in $(seq 1 $SYN_ST_CYCLES); do
        log_message "\nShort-Term Cycle $cycle/$SYN_ST_CYCLES: Baseline for cycle..."
        sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
        local cycle_start_score=$(run_perf_and_sysbench)
        local cycle_start_ipc="$current_ipc"; local cycle_start_l1d="$current_l1d_misses"; local cycle_start_llc="$current_llc_misses"; local cycle_start_branch="$current_branch_misses"
        local cycle_start_mbw=$(run_mbw)
        local cycle_start_ecc_values=$(get_ecc_errors); local cycle_start_ecc_ce="$current_ecc_ce"; local cycle_start_ecc_ue="$current_ecc_ue"
        save_synaptic_short_data "$cycle" "start" "0" "$cycle_start_score" "$cycle_start_ipc" "$cycle_start_l1d" "$cycle_start_llc" "$cycle_start_branch" "$cycle_start_mbw" "$cycle_start_ecc_ce" "$cycle_start_ecc_ue"

        for p_pulse in $(seq 1 $SYN_ST_POT_PULSES); do
            log_message "  Potentiation Pulse $p_pulse/$SYN_ST_POT_PULSES..."
            if [ -x "./hammer" ]; then
                ./hammer --reps "$HAMMER_ITERATIONS" --pattern-length "$HAMMER_PATTERN_LENGTH" \
                         --perform-write "$HAMMER_WRITE_OPS" --thread-count "$HAMMER_THREAD_COUNT" \
                         --access-pattern "$HAMMER_ACCESS_PATTERN" --cache-flush "$HAMMER_CACHE_FLUSH" \
                         --verbose 0 &>/dev/null & hammer_pid=$!
            fi
            apply_stress "$SYN_ST_POTENTIATION_LOAD" "$SYN_ST_PULSE_DURATION_S"
            [ -n "${hammer_pid:-}" ] && { kill $hammer_pid 2>/dev/null || true; wait $hammer_pid 2>/dev/null || true; }
            sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
            local pot_score=$(run_perf_and_sysbench)
            local pot_ipc="$current_ipc"; local pot_l1d="$current_l1d_misses"; local pot_llc="$current_llc_misses"; local pot_branch="$current_branch_misses"
            local pot_mbw=$(run_mbw); local pot_ecc_values=$(get_ecc_errors); local pot_ecc_ce="$current_ecc_ce"; local pot_ecc_ue="$current_ecc_ue"
            save_synaptic_short_data "$cycle" "potentiation" "$p_pulse" "$pot_score" "$pot_ipc" "$pot_l1d" "$pot_llc" "$pot_branch" "$pot_mbw" "$pot_ecc_ce" "$pot_ecc_ue"
        done

        for d_pulse in $(seq 1 $SYN_ST_DEP_PULSES); do
            log_message "  Depression Pulse $d_pulse/$SYN_ST_DEP_PULSES..."
            apply_stress "$SYN_ST_DEPRESSION_LOAD" "$SYN_ST_PULSE_DURATION_S" # Typically idle
            sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
            local dep_score=$(run_perf_and_sysbench)
            local dep_ipc="$current_ipc"; local dep_l1d="$current_l1d_misses"; local dep_llc="$current_llc_misses"; local dep_branch="$current_branch_misses"
            local dep_mbw=$(run_mbw); local dep_ecc_values=$(get_ecc_errors); local dep_ecc_ce="$current_ecc_ce"; local dep_ecc_ue="$current_ecc_ue"
            save_synaptic_short_data "$cycle" "depression" "$d_pulse" "$dep_score" "$dep_ipc" "$dep_l1d" "$dep_llc" "$dep_branch" "$dep_mbw" "$dep_ecc_ce" "$dep_ecc_ue"
        done
        
        log_message "  Forgetting/Relaxation Phase (${SYN_ST_FORGET_DURATION_S}s)..."
        local time_start_forget=$(date +%s)
        while true; do
            local current_time_forget=$(date +%s); local elapsed_forget=$(( current_time_forget - time_start_forget ))
            if [ $elapsed_forget -ge $SYN_ST_FORGET_DURATION_S ]; then break; fi
            if (( elapsed_forget % 5 == 0 )); then # Check every 5s
                 sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
                 local forget_score=$(run_perf_and_sysbench)
                 local forget_ipc="$current_ipc"; local forget_l1d="$current_l1d_misses"; local forget_llc="$current_llc_misses"; local forget_branch="$current_branch_misses"
                 local forget_mbw=$(run_mbw); local forget_ecc_values=$(get_ecc_errors); local forget_ecc_ce="$current_ecc_ce"; local forget_ecc_ue="$current_ecc_ue"
                 save_synaptic_short_data "$cycle" "forget" "$elapsed_forget" "$forget_score" "$forget_ipc" "$forget_l1d" "$forget_llc" "$forget_branch" "$forget_mbw" "$forget_ecc_ce" "$forget_ecc_ue"
            fi; sleep 1
        done
        log_message "  Forgetting phase complete."
    done
    log_message "[✓] SYNAPSE SHORT-TERM MODE COMPLETED."
fi


# =============================================================
#            MODE: SYNAPSE (Long-Term Plasticity Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_LONG" ]; then
    log_message "\n[4] SYNAPSE MODE TEST (Long-Term Plasticity Analogy)"
    ltp_errors=false; ltp_corruption=false
    for cycle in $(seq 1 $SYN_LT_CYCLES); do
        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Potentiation..."
        local temp_before_ltp_pot=$(get_cpu_temp)
        if [ -x "./hammer" ] && [ $((cycle % 2 == 0)) -eq 0 ]; then # Hammer on even cycles
             ./hammer --reps "$HAMMER_ITERATIONS" --pattern-length "$HAMMER_PATTERN_LENGTH" \
                      --perform-write "$HAMMER_WRITE_OPS" --thread-count "$HAMMER_THREAD_COUNT" \
                      --access-pattern "$HAMMER_ACCESS_PATTERN" --cache-flush "$HAMMER_CACHE_FLUSH" \
                      --verbose 0 &>/dev/null & hammer_pid=$!
        fi
        apply_stress "$SYN_LT_POTENTIATION_LOAD" "$SYN_LT_PULSE_DURATION_S"
        [ -n "${hammer_pid:-}" ] && { kill $hammer_pid 2>/dev/null || true; wait $hammer_pid 2>/dev/null || true; unset hammer_pid; }
        
        sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
        local ltp_pot_score=$(run_perf_and_sysbench)
        local ltp_pot_ipc="$current_ipc"; local ltp_pot_l1d="$current_l1d_misses"; local ltp_pot_llc="$current_llc_misses"; local ltp_pot_branch="$current_branch_misses"
        local ltp_pot_mbw=$(run_mbw); local ltp_pot_ecc_values=$(get_ecc_errors); local ltp_pot_ecc_ce="$current_ecc_ce"; local ltp_pot_ecc_ue="$current_ecc_ue"
        local temp_after_ltp_pot=$(get_cpu_temp)
        save_synaptic_long_data "$cycle" "potentiation" "$temp_after_ltp_pot" "$ltp_pot_score" "0" "0" \
                                "$ltp_pot_ipc" "$ltp_pot_l1d" "$ltp_pot_llc" "$ltp_pot_branch" "$ltp_pot_mbw" "$ltp_pot_ecc_ce" "$ltp_pot_ecc_ue"

        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Depression..."
        apply_stress "$SYN_LT_DEPRESSION_LOAD" "$SYN_LT_PULSE_DURATION_S" # Typically idle
        sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
        local ltp_dep_score=$(run_perf_and_sysbench)
        local ltp_dep_ipc="$current_ipc"; local ltp_dep_l1d="$current_l1d_misses"; local ltp_dep_llc="$current_llc_misses"; local ltp_dep_branch="$current_branch_misses"
        local ltp_dep_mbw=$(run_mbw); local ltp_dep_ecc_values=$(get_ecc_errors); local ltp_dep_ecc_ce="$current_ecc_ce"; local ltp_dep_ecc_ue="$current_ecc_ue"
        local temp_after_ltp_dep=$(get_cpu_temp)
        
        local error_detected_ltp=0; local corruption_detected_ltp=0
        if dmesg | tail -n 20 | grep -q -iE 'MCE|uncorrected|critical|panic'; then error_detected_ltp=1; ltp_errors=true; fi
        if (( cycle % 5 == 0 || cycle == SYN_LT_CYCLES )); then # Check corruption periodically and on last cycle
             sync; md5_now=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
             if [ "$md5_orig" != "$md5_now" ]; then corruption_detected_ltp=1; ltp_corruption=true; fi
        fi
        save_synaptic_long_data "$cycle" "depression" "$temp_after_ltp_dep" "$ltp_dep_score" "$error_detected_ltp" "$corruption_detected_ltp" \
                                "$ltp_dep_ipc" "$ltp_dep_l1d" "$ltp_dep_llc" "$ltp_dep_branch" "$ltp_dep_mbw" "$ltp_dep_ecc_ce" "$ltp_dep_ecc_ue"
        if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then break; fi
        if [ $((cycle % (SYN_LT_CYCLES / 5 ))) -eq 0 ]; then log_message "  LTP Cycle $cycle/$SYN_LT_CYCLES completed."; fi
    done

    if [ "$ltp_errors" = false ] && [ "$ltp_corruption" = false ]; then
        log_message "LTP Cycling complete. Starting Retention Test (${SYN_LT_RETENTION_S}s)..."
        sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
        local ret_start_score=$(run_perf_and_sysbench)
        local ret_start_ipc="$current_ipc"; local ret_start_l1d="$current_l1d_misses"; local ret_start_llc="$current_llc_misses"; local ret_start_branch="$current_branch_misses"
        local ret_start_mbw=$(run_mbw); local ret_start_ecc_values=$(get_ecc_errors); local ret_start_ecc_ce="$current_ecc_ce"; local ret_start_ecc_ue="$current_ecc_ue"
        local ret_start_temp=$(get_cpu_temp)
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_start" "$ret_start_temp" "$ret_start_score" "0" "0" \
                                "$ret_start_ipc" "$ret_start_l1d" "$ret_start_llc" "$ret_start_branch" "$ret_start_mbw" "$ret_start_ecc_ce" "$ret_start_ecc_ue"
        
        local time_start_retention=$(date +%s)
        while true; do
            local current_time_ret=$(date +%s); local elapsed_ret=$(( current_time_ret - time_start_retention ))
            if [ $elapsed_ret -ge $SYN_LT_RETENTION_S ]; then break; fi
            if (( elapsed_ret % 10 == 0 && elapsed_ret > 0 )); then # Check every 10s
                 sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
                 local ret_prog_score=$(run_perf_and_sysbench)
                 local ret_prog_ipc="$current_ipc"; local ret_prog_l1d="$current_l1d_misses"; local ret_prog_llc="$current_llc_misses"; local ret_prog_branch="$current_branch_misses"
                 local ret_prog_mbw=$(run_mbw); local ret_prog_ecc_values=$(get_ecc_errors); local ret_prog_ecc_ce="$current_ecc_ce"; local ret_prog_ecc_ue="$current_ecc_ue"
                 local ret_prog_temp=$(get_cpu_temp)
                 save_synaptic_long_data "$SYN_LT_CYCLES" "retention_progress" "$ret_prog_temp" "$ret_prog_score" "0" "0" \
                                         "$ret_prog_ipc" "$ret_prog_l1d" "$ret_prog_llc" "$ret_prog_branch" "$ret_prog_mbw" "$ret_prog_ecc_ce" "$ret_prog_ecc_ue"
            fi; sleep 1
        done
        log_message "Retention Test: Final Checks..."
        sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true
        final_ltp_score=$(run_perf_and_sysbench)
        final_ltp_ipc="$current_ipc"; final_ltp_l1d_misses="$current_l1d_misses"; final_ltp_llc_misses="$current_llc_misses"; final_ltp_branch_misses="$current_branch_misses"
        final_ltp_mbw_score=$(run_mbw); final_ltp_ecc_values=$(get_ecc_errors); final_ltp_ecc_ce="$current_ecc_ce"; final_ltp_ecc_ue="$current_ecc_ue"
        final_ltp_temp=$(get_cpu_temp)

        local error_final_ltp=0; local corruption_final_ltp=0
        md5_after_retention=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
        if [ "$md5_orig" != "$md5_after_retention" ]; then corruption_final_ltp=1; ltp_corruption=true; fi
        if dmesg | tail -n 100 | grep -q -iE 'MCE|uncorrected|critical|panic'; then error_final_ltp=1; ltp_errors=true; fi
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_end" "$final_ltp_temp" "$final_ltp_score" "$error_final_ltp" "$corruption_final_ltp" \
                                "$final_ltp_ipc" "$final_ltp_l1d_misses" "$final_ltp_llc_misses" "$final_ltp_branch_misses" "$final_ltp_mbw_score" "$final_ltp_ecc_ce" "$final_ltp_ecc_ue"
    fi
    log_message "[$(if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then echo "!!! LTP MODE FAILED"; else echo "✓ LTP MODE COMPLETED"; fi)]"
fi

# =============================================================
#                   FINAL ANALYSIS & VERDICT
# =============================================================
log_message "\n[5] FINAL SYSTEM STATE & OVERALL EVALUATION"
sleep 1; sync; echo 3 > /proc/sys/vm/drop_caches || true # Final measurement after cache drop
final_freq=$(get_cpu_freq)
final_temp=$(get_cpu_temp)
final_bench_score=$(run_perf_and_sysbench) # This sets global current_pmc_values for final
final_ipc="$current_ipc"; final_l1d_misses="$current_l1d_misses"; final_llc_misses="$current_llc_misses"; final_branch_misses="$current_branch_misses"
final_mbw_score=$(run_mbw) # This sets global current_mbw_score for final
final_ecc_values=$(get_ecc_errors) # This sets global current_ecc_ce, current_ecc_ue for final
final_ecc_ce="$current_ecc_ce"; final_ecc_ue="$current_ecc_ue"

log_message "Final frequency: ${final_freq} KHz (Baseline: ${baseline_freq} KHz)"
log_message "Final temp: ${final_temp} C (Baseline: ${baseline_temp} C)"
log_message "Final Sysbench Score: ${final_bench_score} (Baseline: ${baseline_bench_score})"
log_message "Final IPC: ${final_ipc} (Baseline: ${baseline_ipc})"
log_message "Final L1D Misses: ${final_l1d_misses} (Baseline: ${baseline_l1d_misses})"
log_message "Final LLC Misses: ${final_llc_misses} (Baseline: ${baseline_llc_misses})"
log_message "Final Branch Misses: ${final_branch_misses} (Baseline: ${baseline_branch_misses})"
log_message "Final MBW Score: ${final_mbw_score} MB/s (Baseline: ${baseline_mbw_score})"
log_message "Final ECC CE: ${final_ecc_ce} (Baseline: ${baseline_ecc_ce})"
log_message "Final ECC UE: ${final_ecc_ue} (Baseline: ${baseline_ecc_ue})"

final_md5=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Final MD5 Check: $final_md5 (Original: $md5_orig)"
if [ "$md5_orig" != "$final_md5" ]; then
    log_message "[!!!] OVERALL DATA CORRUPTION DETECTED!"
fi

save_system_summary # Saves all baseline vs final metrics

# Save test configuration for reference
{
    echo "MODE=$MODE"; echo "TOTAL_DURATION_S=$TOTAL_DURATION_S"
    echo "NEURON_CYCLES=$NEURON_CYCLES"; echo "NEURON_PULSE_AMPLITUDE=$NEURON_PULSE_AMPLITUDE"
    # ... (add all other relevant config variables) ...
    echo "HAMMER_ACCESS_PATTERN=$HAMMER_ACCESS_PATTERN"; echo "HAMMER_CACHE_FLUSH=$HAMMER_CACHE_FLUSH"
    echo "CPU_MODEL=\"$cpu_model\""
} > "${DATA_DIR}/test_config.txt"

overall_verdict_msg=""
if grep -q -iE '\[!!!\].*FAILURE|DATA CORRUPTION DETECTED!' "$LOGFILE"; then
    overall_verdict_msg="❌ SYSTEM FAILURE: Critical errors or data corruption occurred. NS-RAM Analog: Device threshold exceeded, resulting in irreversible state change or damage."
elif grep -q '\[!\] WARN:' "$LOGFILE"; then
    overall_verdict_msg="⚠️  SYSTEM STRESSED BUT STABLE: Tests completed without critical failures, but with warnings. NS-RAM Analog: Device operated near threshold, showing stress effects but no permanent failure."
else
    overall_verdict_msg="✅ SYSTEM RESILIENT: Completed all tests successfully with strong recovery. NS-RAM Analog: Device operated within robust operating region, maintaining state integrity."
fi
log_message "\n--- OVERALL VERDICT (NS-RAM Analogy Interpretation) ---"
log_message "$overall_verdict_msg"

log_message "Test completed at: $(date)"
log_message "Log file saved to: $LOGFILE"
log_message "Data directory for plotting: $DATA_DIR (contains CSVs and temp_perf_output.txt)"
log_message "Review $TEMP_PERF_FILE for detailed perf stat outputs if needed."

exit 0

