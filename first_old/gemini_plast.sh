#!/bin/bash

# ─────────────────────────────────────────────────────────────
# Advanced NS-RAM System-Level Analogy Stress Suite v2.3
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
_PRELIM_LOG_USED=0
prelim_log_install() {
    echo "[+] Installing missing packages: $*" >&2
    _PRELIM_LOG_USED=1
}

# Initial log_message for early use (e.g., package installation warnings)
# Will be overridden by the main log_message function later.
LOGFILE_PRELIM="nsram_analogy_prelim_$(date +%Y%m%d_%H%M%S).log"
prelim_log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >&2
    echo "$msg" >> "$LOGFILE_PRELIM"
    _PRELIM_LOG_USED=1
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
    apt-get update -qq
    if ! command -v perf &>/dev/null; then
        prelim_log_install "linux-tools-common or equivalent for perf"
        apt-get install -y -qq linux-tools-common linux-tools-generic || prelim_log_message "[WARN] Perf installation might require specific linux-tools package for your kernel. Please ensure it's installed."
    fi
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if [ "$pkg" == "linux-tools-$(uname -r)" ] && [ -z "$(uname -r)" ]; then
            prelim_log_message "[WARN] uname -r is empty, skipping installation of kernel-specific linux-tools."
            continue
        fi
        if ! dpkg -s "$pkg" &>/dev/null; then
            prelim_log_install "$pkg"
            apt-get install -y -qq "$pkg" || prelim_log_message "[WARN] Failed to install $pkg, continuing. Some features might not work."
        fi
    done
    if ! command -v cpupower &>/dev/null; then
        prelim_log_install "cpupower"
        apt-get install -y -qq cpupower || apt-get install -y -qq linux-tools-generic || prelim_log_message "[WARN] Failed to install cpupower, continuing."
    fi
    if command -v sensors-detect &>/dev/null; then
        echo "[*] Running sensors-detect (auto-confirm)..." >&2
        yes | sensors-detect >/dev/null 2>&1 || true
    else
        prelim_log_message "[WARN] sensors-detect not found. Temperature readings might not be available."
    fi
else
    echo "[ERROR] Unsupported package manager. Please manually install required packages:" >&2
    printf "  %s\n" "${REQUIRED_PACKAGES[@]}" >&2
    exit 1
fi


# --- Configuration ---
MODE="ALL"
TOTAL_DURATION_S=300
LOGFILE="nsram_analogy_results_$(date +%Y%m%d_%H%M%S).log"
TEST_DATA_FILE="stress_test_data.bin"
DATA_SIZE_MB=25

RUN_ID=$(date +%Y%m%d_%H%M%S)
DATA_DIR="stress_data_${RUN_ID}"
mkdir -p "$DATA_DIR"
TEMP_PERF_FILE="${DATA_DIR}/temp_perf_output.txt"

NEURON_DATA="${DATA_DIR}/neuron_data.csv"
SYNAPTIC_SHORT_DATA="${DATA_DIR}/synaptic_short_data.csv"
SYNAPTIC_LONG_DATA="${DATA_DIR}/synaptic_long_data.csv"
SYSTEM_SUMMARY="${DATA_DIR}/system_summary.csv"

log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >&2
    echo "$msg" >> "$LOGFILE"
}

# Initialize data files AFTER main log_message is defined
echo "timestamp,cycle,phase,temp,freq,recovery_time,error_detected,ipc,l1d_misses_pmc,llc_misses_pmc,branch_misses_pmc,mbw_score_mbps,ecc_ce_count,ecc_ue_count" > "$NEURON_DATA"
echo "timestamp,cycle,phase,pulse_or_elapsed,bench_score,percent_of_baseline,ipc,l1d_misses_pmc,llc_misses_pmc,branch_misses_pmc,mbw_score_mbps,ecc_ce_count,ecc_ue_count" > "$SYNAPTIC_SHORT_DATA"
echo "timestamp,cycle,phase,temp,bench_score,error_detected,corruption_detected,ipc,l1d_misses_pmc,llc_misses_pmc,branch_misses_pmc,mbw_score_mbps,ecc_ce_count,ecc_ue_count" > "$SYNAPTIC_LONG_DATA"
echo "metric,baseline,final,percent_change" > "$SYSTEM_SUMMARY"

NEURON_PULSE_AMPLITUDE="max"
NEURON_PULSE_INTERVAL_ON_S=5
NEURON_PULSE_INTERVAL_OFF_S=5
NEURON_CYCLES=5

SYN_ST_POTENTIATION_LOAD="high"
SYN_ST_DEPRESSION_LOAD="idle"
SYN_ST_PULSE_DURATION_S=3
SYN_ST_POT_PULSES=3
SYN_ST_DEP_PULSES=3
SYN_ST_FORGET_DURATION_S=20
SYN_ST_CYCLES=2

SYN_LT_POTENTIATION_LOAD="max"
SYN_LT_DEPRESSION_LOAD="idle"
SYN_LT_PULSE_DURATION_S=8
SYN_LT_CYCLES=10
SYN_LT_RETENTION_S=30

USE_RAPL=false
RAPL_POWER_LIMIT_W=50

HAMMER_ITERATIONS=2000000
HAMMER_PATTERN_LENGTH=4
HAMMER_WRITE_OPS=1
HAMMER_THREAD_COUNT=2
HAMMER_ACCESS_PATTERN="seq"
HAMMER_CACHE_FLUSH="lines"

declare -A STRESS_PARAMS
STRESS_PARAMS["max"]="--cpu $(nproc) --matrix $(nproc) --vm $(nproc) --vm-bytes 1G --cpu-method all"
STRESS_PARAMS["high"]="--cpu $(nproc) --matrix 0 --vm $(nproc) --vm-bytes 512M --cpu-method int64,float"
STRESS_PARAMS["medium"]="--cpu $(($(nproc)/2)) --matrix 0 --vm 0 --cpu-method bitops"
STRESS_PARAMS["low"]="--cpu 1 --vm 0 --cpu-method trivial"
STRESS_PARAMS["idle"]=""

baseline_freq=0; baseline_temp=0; baseline_bench_score=0
baseline_ipc="N/A"; baseline_l1d_misses="N/A"; baseline_llc_misses="N/A"; baseline_branch_misses="N/A"
baseline_mbw_score="N/A"; baseline_ecc_ce="N/A"; baseline_ecc_ue="N/A"

cpu_model=""; final_freq=0; final_temp=0; final_bench_score=0
final_ipc="N/A"; final_l1d_misses="N/A"; final_llc_misses="N/A"; final_branch_misses="N/A"
final_mbw_score="N/A"; final_ecc_ce="N/A"; final_ecc_ue="N/A"


parse_perf_output() {
    local perf_file="$1"
    local ipc="N/A"; local l1d_misses="N/A"; local llc_misses="N/A"; local branch_misses="N/A"
    local instructions_val="N/A"; local cycles_val="N/A"

    if [ ! -f "$perf_file" ] || [ ! -s "$perf_file" ]; then
        log_message "    WARN: Perf output file '$perf_file' not found or empty."
        echo "N/A,N/A,N/A,N/A"; return
    fi

    if grep -q ',' "$perf_file"; then
        log_message "    DEBUG: Parsing perf CSV output from $perf_file"
        while IFS=, read -r val unit ev_name run_ms perc metric_val metric_unit junk || [[ -n "$val" ]]; do
            ev_name=$(echo "$ev_name" | xargs); val=$(echo "$val" | tr -d '[:space:]')
            [[ "$val" == "<not counted>" || "$val" == "<not supported>" ]] && val="N/A"
            case "$ev_name" in
                instructions) instructions_val="$val" ;;
                cycles|cpu-cycles) cycles_val="$val" ;;
                L1-dcache-load-misses|l1d_cache_refill.rd|l1d.repl|L1-dcache-misses)
                    if [[ "$l1d_misses" == "N/A" || "$l1d_misses" == "" ]]; then l1d_misses="$val"; fi ;;
                LLC-load-misses|ll_cache_miss_rd|cache-misses)
                    if [[ "$ev_name" == *"LLC-load-misses"* || "$ev_name" == *"ll_cache_miss_rd"* ]]; then
                        if [[ "$llc_misses" == "N/A" || "$llc_misses" == "" ]]; then llc_misses="$val"; fi
                    elif [[ "$ev_name" == *"cache-misses"* && ("$llc_misses" == "N/A" || "$llc_misses" == "") ]]; then
                        llc_misses="$val"; fi ;;
                branch-misses) branch_misses="$val" ;;
            esac
        done < <(grep -v '^#' "$perf_file" | grep -v '^$' | tr -d '\r')

        log_message "    DEBUG: For IPC calc: instructions_val='${instructions_val}', cycles_val='${cycles_val}'"
        if [[ "$instructions_val" =~ ^[0-9]+$ && "$cycles_val" =~ ^[0-9]+$ && "$cycles_val" -ne 0 && "$instructions_val" != "N/A" && "$cycles_val" != "N/A" ]]; then
            ipc=$(echo "scale=2; $instructions_val / $cycles_val" | bc)
        else
            log_message "    DEBUG: IPC calculation conditions not met. instructions='${instructions_val}', cycles='${cycles_val}'"
            ipc="N/A"; fi
    else
        log_message "    WARN: Perf output file '$perf_file' not in CSV format or CSV parsing failed, trying space-separated."
        # ... (fallback parsing, ensure it sets local_ipc, local_l1d_misses etc.) ...
        local raw_instructions=$(grep -E '[0-9,]+[[:space:]]+instructions' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g')
        local raw_cycles=$(grep -E '[0-9,]+[[:space:]]+cycles' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g')
        if [[ "$raw_instructions" =~ ^[0-9]+$ && "$raw_cycles" =~ ^[0-9]+$ && "$raw_cycles" -ne 0 ]]; then
            ipc=$(echo "scale=2; $raw_instructions / $raw_cycles" | bc)
        fi
        l1d_misses=$(grep -E '[0-9,]+[[:space:]]+(L1-dcache-load-misses|l1d.repl)' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g' || echo "N/A")
        llc_misses=$(grep -E '[0-9,]+[[:space:]]+(LLC-load-misses|cache-misses)' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g' || echo "N/A")
        branch_misses=$(grep -E '[0-9,]+[[:space:]]+branch-misses' "$perf_file" | head -n1 | awk '{print $1}' | sed 's/,//g' || echo "N/A")
    fi
    
    [ -z "$ipc" ] && ipc="N/A"; [ "$ipc" == "." ] && ipc="N/A"; [[ ! "$ipc" =~ ^[0-9]+(\.[0-9]+)?$ && "$ipc" != "N/A" ]] && ipc="N/A"
    l1d_misses=${l1d_misses:-N/A}; [[ ! "$l1d_misses" =~ ^[0-9]+$ && "$l1d_misses" != "N/A" ]] && l1d_misses="N/A"
    llc_misses=${llc_misses:-N/A}; [[ ! "$llc_misses" =~ ^[0-9]+$ && "$llc_misses" != "N/A" ]] && llc_misses="N/A"
    branch_misses=${branch_misses:-N/A}; [[ ! "$branch_misses" =~ ^[0-9]+$ && "$branch_misses" != "N/A" ]] && branch_misses="N/A"
    echo "${ipc},${l1d_misses},${llc_misses},${branch_misses}"
}

save_neuron_data() {
    local timestamp; timestamp=$(date +%s)
    local cycle=$1 phase=$2 temp=$3 freq=$4 recovery_time=$5 error_detected=$6
    local ipc_val=$7 l1d_val=$8 llc_val=$9 branch_val=${10}
    local mbw_val=${11} ecc_ce=${12} ecc_ue=${13}
    echo "$timestamp,$cycle,$phase,$temp,$freq,$recovery_time,$error_detected,$ipc_val,$l1d_val,$llc_val,$branch_val,$mbw_val,$ecc_ce,$ecc_ue" >> "$NEURON_DATA"
}

save_synaptic_short_data() {
    local timestamp; timestamp=$(date +%s)
    local cycle=$1 phase=$2 pulse_or_elapsed=$3 bench_score=$4
    local ipc_val=$5 l1d_val=$6 llc_val=$7 branch_val=$8
    local mbw_val=$9 ecc_ce=${10} ecc_ue=${11}
    local percent_baseline="N/A"
    if [[ "$bench_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" != "0" && "$baseline_bench_score" != "N/A" && $(echo "$baseline_bench_score != 0" | bc -l) -eq 1 ]]; then
        percent_baseline=$(echo "scale=2; 100 * $bench_score / $baseline_bench_score" | bc)
    fi
    echo "$timestamp,$cycle,$phase,$pulse_or_elapsed,$bench_score,$percent_baseline,$ipc_val,$l1d_val,$llc_val,$branch_val,$mbw_val,$ecc_ce,$ecc_ue" >> "$SYNAPTIC_SHORT_DATA"
}

save_synaptic_long_data() {
    local timestamp; timestamp=$(date +%s)
    local cycle=$1 phase=$2 temp=$3 bench_score=$4 error_detected=$5 corruption_detected=$6
    local ipc_val=$7 l1d_val=$8 llc_val=$9 branch_val=${10}
    local mbw_val=${11} ecc_ce=${12} ecc_ue=${13}
    echo "$timestamp,$cycle,$phase,$temp,$bench_score,$error_detected,$corruption_detected,$ipc_val,$l1d_val,$llc_val,$branch_val,$mbw_val,$ecc_ce,$ecc_ue" >> "$SYNAPTIC_LONG_DATA"
}

save_system_summary_metric() {
    local metric_name="$1"; local base_val="$2"; local final_val="$3"; local percent_change="N/A"
    if [[ "$base_val" =~ ^[0-9]+(\.[0-9]+)?$ && "$final_val" =~ ^[0-9]+(\.[0-9]+)?$ && "$base_val" != "0" && "$base_val" != "N/A" && $(echo "$base_val != 0" | bc -l) -eq 1 ]]; then
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
    save_system_summary_metric "ecc_ce_total" "$baseline_ecc_ce" "$final_ecc_ce"
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
    [ -z "$temp_val" ] || [[ ! "$temp_val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && temp_val="N/A"; echo "$temp_val"
}

run_perf_and_sysbench() {
    log_message "  Running sysbench CPU benchmark with perf..."
    local sysbench_score="N/A"; local perf_events="cycles,instructions,L1-dcache-load-misses,LLC-load-misses,branch-misses"
    local local_ipc="N/A"; local local_l1d_misses="N/A"; local local_llc_misses="N/A"; local local_branch_misses="N/A"
    rm -f "$TEMP_PERF_FILE"; local perf_cmd_failed=0

    ( set +e 
      if perf stat -x, -e "$perf_events" --log-fd 1 sleep 0.1 &>/dev/null; then
          log_message "    Using perf stat with CSV output."
          perf stat -x, -e "$perf_events" -o "$TEMP_PERF_FILE" --append -- sysbench cpu --cpu-max-prime=15000 --threads="$(nproc)" run &>/dev/null
      else
          log_message "    Perf stat CSV output not available or failed, falling back to standard output parsing."
          perf stat -e "$perf_events" -o "$TEMP_PERF_FILE" --append -- sysbench cpu --cpu-max-prime=15000 --threads="$(nproc)" run &>/dev/null; fi
      [ $? -ne 0 ] && { log_message "    WARN: 'perf stat ... sysbench' command failed."; perf_cmd_failed=1; }
    )
    local raw_sysbench_output; raw_sysbench_output=$(sysbench cpu --cpu-max-prime=15000 --threads="$(nproc)" run 2>/dev/null)
    if [ $? -ne 0 ]; then log_message "    WARN: Sysbench command for score failed."; sysbench_score="N/A"
    else
        sysbench_score=$(echo "$raw_sysbench_output" | grep 'events per second:' | awk '{print $4}' | tr -d '\r\n')
        if [[ ! "$sysbench_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_message "    WARN: Sysbench failed to produce valid score from output."; sysbench_score="N/A"; else
            log_message "    Sysbench score: $sysbench_score events/sec"; fi; fi
    
    if [ "$perf_cmd_failed" -eq 1 ] && [ ! -f "$TEMP_PERF_FILE" ]; then
      log_message "    WARN: Skipping PMC parsing as perf command failed and no output file."
    else
      local pmc_results_str; pmc_results_str=$(parse_perf_output "$TEMP_PERF_FILE")
      local_ipc=$(echo "$pmc_results_str" | cut -d, -f1); local_l1d_misses=$(echo "$pmc_results_str" | cut -d, -f2)
      local_llc_misses=$(echo "$pmc_results_str" | cut -d, -f3); local_branch_misses=$(echo "$pmc_results_str" | cut -d, -f4)
      log_message "    Perf Metrics: IPC=${local_ipc}, L1D Misses=${local_l1d_misses}, LLC Misses=${local_llc_misses}, Branch Misses=${local_branch_misses}"; fi
    printf "%s,%s,%s,%s,%s" "${sysbench_score:-N/A}" "${local_ipc:-N/A}" "${local_l1d_misses:-N/A}" "${local_llc_misses:-N/A}" "${local_branch_misses:-N/A}"
}

run_mbw() {
    log_message "  Running mbw memory benchmark..."; local mbw_score="N/A" 
    if command -v mbw &>/dev/null; then
        local mbw_raw_output; mbw_raw_output=$(mbw -q -n 100 256 2>&1)
        mbw_score=$(echo "$mbw_raw_output" | grep -E '^AVG Method: MEMCPY' | awk '{val=$(NF-1); gsub(/[^0-9.]/,"",val); print val}' | head -n1)
        [[ ! "$mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]] && \
            mbw_score=$(echo "$mbw_raw_output" | grep -E '^AVG Method: DUMB' | awk '{val=$(NF-1); gsub(/[^0-9.]/,"",val); print val}' | head -n1)
        [[ ! "$mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]] && \
            mbw_score=$(echo "$mbw_raw_output" | grep -E '^AVG Method: MCBLOCK' | awk '{val=$(NF-1); gsub(/[^0-9.]/,"",val); print val}' | head -n1)
        if [[ ! "$mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_message "    WARN: Failed to parse AVG line. Averaging individual MEMCPY results."
            mbw_score=$(echo "$mbw_raw_output" | grep 'Method: MEMCPY' | awk '{val=$(NF-1); gsub(/[^0-9.]/,"",val); sum+=val; count++} END {if (count>0) printf "%.2f", sum/count; else print "N/A"}')
        fi
        if [[ ! "$mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_message "    WARN: Failed to average MEMCPY. Averaging DUMB results."
            mbw_score=$(echo "$mbw_raw_output" | grep 'Method: DUMB' | awk '{val=$(NF-1); gsub(/[^0-9.]/,"",val); sum+=val; count++} END {if (count>0) printf "%.2f", sum/count; else print "N/A"}')
        fi
        if [[ ! "$mbw_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then log_message "    WARN: Failed to parse mbw output."; mbw_score="N/A"
        else log_message "    MBW Score: ${mbw_score} MB/s"; fi
    else log_message "    WARN: mbw not found. Skipping memory bandwidth test."; fi
    printf "%s" "${mbw_score:-N/A}"
}

get_ecc_errors() {
    log_message "  Checking ECC errors..."; local ecc_ce="N/A"; local ecc_ue="N/A"
    if command -v edac-ctl &>/dev/null; then
        if edac-ctl --status &>/dev/null; then
            ecc_ce=$(edac-ctl --error_count 2>/dev/null | grep 'Corrected:' | awk '{print $2}' || echo "0")
            ecc_ue=$(edac-ctl --error_count 2>/dev/null | grep 'Uncorrected:' | awk '{print $2}' || echo "0")
            log_message "    ECC Errors: Corrected=${ecc_ce:-0}, Uncorrected=${ecc_ue:-0}"
        else log_message "    WARN: EDAC kernel modules not loaded or no errors reported by edac-ctl. Skipping ECC check."; fi
    else log_message "    WARN: edac-utils not found. Skipping ECC check."; fi
    printf "%s,%s" "${ecc_ce:-N/A}" "${ecc_ue:-N/A}"
}

apply_stress() {
    local level=$1; local duration_s=$2; local stress_cmd="${STRESS_PARAMS[$level]}"
    if [ -z "$stress_cmd" ] || [ "$level" == "idle" ]; then
        log_message "  Applying IDLE state for ${duration_s}s."; sleep "$duration_s"; return; fi
    log_message "  Applying stress level '$level' for ${duration_s}s: $stress_cmd"
    stress-ng $stress_cmd --timeout "${duration_s}s" --metrics-brief --log-brief &> /dev/null &
    local stress_pid=$!; local waited_time=0
    while [ $waited_time -lt "$duration_s" ]; do
        sleep 1; if ! ps -p $stress_pid > /dev/null; then
            log_message "    stress-ng process $stress_pid finished early or was killed."; break; fi
        waited_time=$((waited_time + 1)); done
    if ps -p $stress_pid > /dev/null; then
        log_message "    Timeout reached for stress level '$level', ensuring process $stress_pid is stopped."
        kill $stress_pid 2>/dev/null || true ; fi
    wait $stress_pid 2>/dev/null || true; log_message "  Stress level '$level' application finished."
}

set_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Setting RAPL power limit to ${RAPL_POWER_LIMIT_W}W..."
        (set +e; powercap-set -p intel-rapl -z 0 -c 0 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 0 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        log_message "    WARN: Failed to set RAPL package-0 long term limit.")
        (set +e; powercap-set -p intel-rapl -z 0 -c 1 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 1 -l "$((RAPL_POWER_LIMIT_W * 1000000))" --quiet || \
        log_message "    WARN: Failed to set RAPL package-0 short term limit (continuing).")
    elif [ "$USE_RAPL" = true ]; then log_message "    WARN: USE_RAPL is true, but powercap-set command not found."; fi
}

reset_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Resetting RAPL power limit to default (high value)..."
        local high_limit_uw=$((250 * 1000000)) 
        (set +e; powercap-set -p intel-rapl -z 0 -c 0 -l "$high_limit_uw" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 0 -l "$high_limit_uw" --quiet || \
        log_message "    WARN: Failed to reset RAPL package-0 long term limit.")
        (set +e; powercap-set -p intel-rapl -z 0 -c 1 -l "$high_limit_uw" --quiet || \
        powercap-set -p intel-rapl:0 -z 0 -c 1 -l "$high_limit_uw" --quiet || \
        log_message "    WARN: Failed to reset RAPL package-0 short term limit (continuing)."); fi
}

_CLEANUP_RUNNING=0 
cleanup() {
  if [ "$_CLEANUP_RUNNING" -ne 0 ]; then echo "[WARN] Cleanup re-entry ignored." >&2; return; fi; _CLEANUP_RUNNING=1
  local old_int_trap; old_int_trap=$(trap -p INT); local old_term_trap; old_term_trap=$(trap -p TERM); trap '' INT TERM
  log_message "[*] Cleaning up processes and files..."
  if [ -n "$BASHPID" ]; then
      local pgid_val; pgid_val=$(ps -o pgid= -p "$BASHPID" | grep -o '[0-9]*' || true) 
      if [ -n "$pgid_val" ] && [ "$pgid_val" -ne "$BASHPID" ] && [ "$pgid_val" -ne 0 ]; then 
          log_message "  Attempting to kill process group: -$pgid_val"
          kill -- "-$pgid_val" 2>/dev/null || true; sleep 0.1; kill -9 -- "-$pgid_val" 2>/dev/null || true
      else log_message "  Process group ID not found or is self, using pkill -P $$"; pkill -P $$ 2>/dev/null || true; sleep 0.1; pkill -9 -P $$ 2>/dev/null || true; fi
  else pkill -P $$ 2>/dev/null || true; sleep 0.1; pkill -9 -P $$ 2>/dev/null || true; fi
  wait 2>/dev/null || true; log_message "[*] Resetting system state..."
  reset_rapl_limit
  if command -v cpupower &>/dev/null; then log_message "  Attempting to set CPU governor to powersave..."
      (set +e; cpupower frequency-set -g powersave &>/dev/null || log_message "    WARN: Failed to set powersave governor."); fi
  if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then log_message "  Attempting to re-enable Intel P-state turbo..."
      (set +e; echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo || log_message "    WARN: Failed to re-enable turbo (intel_pstate).")
  elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then log_message "  Attempting to re-enable CPU frequency boost..."
      (set +e; echo 1 > /sys/devices/system/cpu/cpufreq/boost || log_message "    WARN: Failed to re-enable boost (cpufreq)."); fi
  if [ -f /proc/sys/kernel/randomize_va_space ]; then log_message "  Attempting to reset ASLR to default..."
      (set +e; echo 2 > /proc/sys/kernel/randomize_va_space || log_message "    WARN: Failed to reset ASLR."); fi
  rm -f hammer hammer.c spec_havoc spec_havoc.o spec_havoc.S "$TEST_DATA_FILE" "$TEMP_PERF_FILE" 2>/dev/null || true
  log_message "[*] Cleanup finished."; eval "$old_int_trap" 2>/dev/null; eval "$old_term_trap" 2>/dev/null; _CLEANUP_RUNNING=0
}
trap cleanup EXIT INT TERM

compile_hammer() {
    log_message "[*] Compiling enhanced hammer tool (v2.2)..."
    cat > hammer.c << 'HAMMER_EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h> 
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <getopt.h> 
#include <sys/mman.h> // For sysconf

typedef enum { ACCESS_SEQ, ACCESS_RAND, ACCESS_STRIDE, ACCESS_VICTIM_AGGRESSOR } access_pattern_t;
typedef enum { CACHE_FLUSH_NONE, CACHE_FLUSH_LINES, CACHE_FLUSH_ALL } cache_flush_t;

typedef struct {
    size_t reps; size_t row_size; size_t distance; size_t pattern_length;
    uint8_t check_corruption; uint8_t perform_write; uint8_t verbose; size_t thread_count;
    access_pattern_t access_pattern; cache_flush_t cache_flush_mode; uint32_t random_seed;
} hammer_config_t;

typedef struct {
    void *mem_region; size_t mem_region_size; size_t offset_in_region; 
    hammer_config_t *config; uint8_t *ref_data; uint8_t *corruption_detected_flag; int thread_id;
} hammer_thread_data_t;

uint64_t get_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
uint32_t prng_state;
void init_prng(uint32_t seed) { prng_state = seed; }
uint32_t simple_rand() { prng_state = (1103515245 * prng_state + 12345) & 0x7FFFFFFF; return prng_state; }

void *hammer_thread(void *arg) {
    hammer_thread_data_t *data = (hammer_thread_data_t *)arg; hammer_config_t *cfg = data->config;
    volatile uint8_t *base_addr = (uint8_t *)data->mem_region + data->offset_in_region;
    size_t current_op_count = 0;
    size_t max_offset = 0;
    if (data->mem_region_size > data->offset_in_region + cfg->row_size) { // Basic check
        max_offset = data->mem_region_size - data->offset_in_region - cfg->row_size;
    }
    if (cfg->pattern_length > 0 && cfg->distance > 0) {
         size_t pattern_span = cfg->pattern_length * cfg->distance;
         if (pattern_span < max_offset) max_offset = pattern_span;
    }
    if (max_offset == 0 && data->mem_region_size > data->offset_in_region + cfg->row_size) {
        max_offset = data->mem_region_size - data->offset_in_region - cfg->row_size -1;
        if(max_offset > data->mem_region_size) max_offset =0; // prevent overflow if row_size is huge
    }


    for (size_t i = 0; i < cfg->reps; i++) {
        for (size_t p_idx = 0; p_idx < cfg->pattern_length; ++p_idx) {
            volatile uint64_t *target_addr; size_t current_byte_offset = 0;
            if (max_offset > 0) {
                switch (cfg->access_pattern) {
                    case ACCESS_SEQ: current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1); break;
                    case ACCESS_RAND: current_byte_offset = simple_rand() % (max_offset + 1);
                                      current_byte_offset -= current_byte_offset % sizeof(uint64_t); break;
                    case ACCESS_STRIDE: current_byte_offset = (current_op_count * cfg->distance) % (max_offset + 1); break;
                    default: current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1); break;
                }
            }
            target_addr = (volatile uint64_t *)(base_addr + current_byte_offset);
            if ((uintptr_t)target_addr >= (uintptr_t)(base_addr) && 
                (uintptr_t)target_addr < (uintptr_t)(data->mem_region + data->mem_region_size - sizeof(uint64_t) + 1) ) {
                if (cfg->cache_flush_mode == CACHE_FLUSH_LINES) _mm_clflush((const void *)target_addr);
                if (cfg->perform_write) *target_addr = i + p_idx; 
                else { volatile uint64_t dummy = *target_addr; (void)dummy; }
                _mm_mfence(); 
            } current_op_count++;
        }
        if (cfg->cache_flush_mode == CACHE_FLUSH_ALL) _mm_mfence();
        _mm_sfence(); 
        if (cfg->check_corruption && data->ref_data && !(*data->corruption_detected_flag) && (i % 10000 == 0)) { 
            for (size_t p_idx = 0; p_idx < cfg->pattern_length; ++p_idx) {
                 size_t check_offset = (max_offset > 0) ? (p_idx * cfg->distance) % (max_offset + 1) : 0;
                 for (size_t k=0; k < sizeof(uint64_t) && (data->offset_in_region + check_offset + k) < data->mem_region_size; ++k) {
                    if ((uintptr_t)(base_addr + check_offset + k) < (uintptr_t)(data->mem_region + data->mem_region_size) ) {
                        uint8_t expected = data->ref_data[data->offset_in_region + check_offset + k];
                        uint8_t actual = ((uint8_t*)data->mem_region)[data->offset_in_region + check_offset + k];
                        if (!cfg->perform_write && expected != actual) {
                             *data->corruption_detected_flag = 1;
                             if(cfg->verbose) printf("[T%d] Corruption@%p exp %02x got %02x\n", data->thread_id, (void*)(base_addr+check_offset+k), expected, actual);
                            goto end_thread_loop; 
                        }
                    }
                 }
            }
        }
    }
end_thread_loop: return NULL;
}
void print_usage(char *argv0) { /* ... unchanged ... */ }
int main(int argc, char *argv[]) {
    hammer_config_t config = { .reps = 2000000, .row_size = 4096, .distance = 8192, .pattern_length = 4,
        .check_corruption = 1, .perform_write = 1, .verbose = 1, .thread_count = 2,
        .access_pattern = ACCESS_SEQ, .cache_flush_mode = CACHE_FLUSH_LINES, .random_seed = (uint32_t)time(NULL) };
    /* getopt_long unchanged */
    static struct option long_options[] = {
        {"reps", required_argument, 0, 'r'}, {"row-size", required_argument, 0, 's'},
        {"distance", required_argument, 0, 'd'}, {"pattern-length", required_argument, 0, 'l'},
        {"check-corruption", required_argument, 0, 'c'}, {"perform-write", required_argument, 0, 'w'},
        {"thread-count", required_argument, 0, 't'}, {"access-pattern", required_argument, 0, 'a'},
        {"cache-flush", required_argument, 0, 'f'}, {"seed", required_argument, 0, 'e'},
        {"verbose", required_argument, 0, 'v'}, {"help", no_argument, 0, 'h'}, {0,0,0,0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "r:s:d:l:c:w:t:a:f:e:v:h", long_options, NULL)) != -1) {
        switch (opt) {
            case 'r': config.reps = atoll(optarg); break; case 's': config.row_size = atoll(optarg); break;
            case 'd': config.distance = atoll(optarg); break; case 'l': config.pattern_length = atoll(optarg); break;
            case 'c': config.check_corruption = atoi(optarg); break; case 'w': config.perform_write = atoi(optarg); break;
            case 't': config.thread_count = atoi(optarg); break;
            case 'a': if (strcmp(optarg, "seq") == 0) config.access_pattern = ACCESS_SEQ;
                      else if (strcmp(optarg, "rand") == 0) config.access_pattern = ACCESS_RAND;
                      else if (strcmp(optarg, "stride") == 0) config.access_pattern = ACCESS_STRIDE;
                      else if (strcmp(optarg, "victim") == 0) config.access_pattern = ACCESS_VICTIM_AGGRESSOR;
                      else { fprintf(stderr, "Invalid access pattern: %s\n", optarg); return 1; } break;
            case 'f': if (strcmp(optarg, "none") == 0) config.cache_flush_mode = CACHE_FLUSH_NONE;
                      else if (strcmp(optarg, "lines") == 0) config.cache_flush_mode = CACHE_FLUSH_LINES;
                      else if (strcmp(optarg, "all") == 0) config.cache_flush_mode = CACHE_FLUSH_ALL;
                      else { fprintf(stderr, "Invalid cache flush mode: %s\n", optarg); return 1; } break;
            case 'e': config.random_seed = atoi(optarg); break; case 'v': config.verbose = atoi(optarg); break;
            case 'h': print_usage(argv[0]); return 0; default: print_usage(argv[0]); return 1;
        }
    }
    init_prng(config.random_seed);
    size_t page_size = sysconf(_SC_PAGESIZE); if(page_size <=0) page_size=4096;
    if(config.row_size == 0) config.row_size = page_size; else if (config.row_size % page_size !=0) config.row_size = ((config.row_size / page_size) +1) * page_size;

    size_t total_mem_size = config.row_size * (config.pattern_length > 0 ? config.pattern_length : 2) * (config.thread_count > 0 ? config.thread_count : 1) * 2;
    if (total_mem_size < config.row_size * 4) total_mem_size = config.row_size * 4; // Min sensible size.
    if (total_mem_size == 0) total_mem_size = page_size * 10;


    void *mem_region = aligned_alloc(page_size, total_mem_size);
    if (!mem_region) { perror("Memory allocation failed"); return 1; }
    memset(mem_region, 0xA5, total_mem_size); 
    uint8_t *ref_data_copy = NULL;
    if (config.check_corruption && !config.perform_write) { 
        ref_data_copy = malloc(total_mem_size);
        if (!ref_data_copy) { perror("Ref data allocation failed"); free(mem_region); return 1; }
        memcpy(ref_data_copy, mem_region, total_mem_size); 
    } else if (config.check_corruption && config.perform_write) {
        if(config.verbose) printf("WARN: Corruption check with perform_write=1 is complex.\n");}
    if (config.verbose) printf("Hammer: Reps=%zuM, PatLen=%zu, Write=%d, Thrds=%zu, Acc=%d, Flush=%d, Seed=%u, Mem=%.2fMB\n",
               config.reps/1000000, config.pattern_length, config.perform_write, config.thread_count,
               config.access_pattern, config.cache_flush_mode, config.random_seed, (double)total_mem_size/(1024.0*1024.0));
    pthread_t *threads = malloc(config.thread_count * sizeof(pthread_t));
    hammer_thread_data_t *thread_data_array = malloc(config.thread_count * sizeof(hammer_thread_data_t));
    uint8_t overall_corruption_detected = 0; uint64_t start_ns = get_ns();
    size_t per_thread_mem_span = (config.thread_count > 0) ? (total_mem_size / config.thread_count) : total_mem_size;
    for (size_t t = 0; t < config.thread_count; t++) {
        thread_data_array[t].mem_region = mem_region; thread_data_array[t].mem_region_size = total_mem_size; 
        thread_data_array[t].offset_in_region = t * per_thread_mem_span; thread_data_array[t].config = &config;
        thread_data_array[t].ref_data = ref_data_copy; thread_data_array[t].corruption_detected_flag = &overall_corruption_detected;
        thread_data_array[t].thread_id = t; pthread_create(&threads[t], NULL, hammer_thread, &thread_data_array[t]);
    }
    for (size_t t = 0; t < config.thread_count; t++) pthread_join(threads[t], NULL);
    uint64_t end_ns = get_ns(); double elapsed_s = 0.0; if (end_ns > start_ns) elapsed_s = (end_ns - start_ns)/1000000000.0;
    double rate = 0.0; if (elapsed_s > 0 && config.reps > 0) rate = (config.reps * config.thread_count)/elapsed_s/1000000.0;
    if (config.verbose) { printf("Results: Time=%.2fs, Rate=%.2f M iter/s\n", elapsed_s, rate);
        if (config.check_corruption && !config.perform_write) printf("  STATUS: %s\n", overall_corruption_detected ? "CORRUPTION DETECTED" : "No corruption detected");}
    free(mem_region); free(threads); free(thread_data_array); if (ref_data_copy) free(ref_data_copy);
    return overall_corruption_detected ? 2 : 0; 
}
HAMMER_EOF
    gcc -O2 -march=native -pthread -o hammer hammer.c -Wall || {
        log_message "!!! Hammer compilation failed with -march=native!"
        log_message "Retrying Hammer compilation without -march=native..."
        gcc -O2 -pthread -o hammer hammer.c -Wall || {
             log_message "!!! Hammer compilation failed (even without -march=native)!"; return 1; }
    }
    log_message "[+] Hammer compilation successful."; return 0
}
compile_spec_havoc() { /* ... unchanged ... */ 
    log_message "[*] Compiling enhanced spec_havoc tool (v2.1)..."
    cat > spec_havoc.S << 'SPEC_HAVOC_EOF'
.section .text;.global _start;_start:vmovaps %ymm0,%ymm1;vmovaps %ymm0,%ymm2;vmovaps %ymm0,%ymm3;vmovaps %ymm0,%ymm4;vmovaps %ymm0,%ymm5;vmovaps %ymm0,%ymm6;vmovaps %ymm0,%ymm7;xor %r12,%r12;mov $200000000,%r13;xor %r14,%r14;mov $0x5555555555555555,%rax;mov $0xaaaaaaaaaaaaaaaa,%rbx;mov $0x3333333333333333,%rcx;mov $0xcccccccccccccccc,%rdx;.main_loop:inc %r14;cmp %r13,%r14;jge .exit;test $0x1FFF,%r14;jnz .skip_phase_change;inc %r12;and $3,%r12;.skip_phase_change:cmp $0,%r12;je .phase0;cmp $1,%r12;je .phase1;cmp $2,%r12;je .phase2;jmp .phase3;.phase0:vaddps %ymm0,%ymm1,%ymm2;vmulps %ymm2,%ymm3,%ymm4;vdivps %ymm4,%ymm5,%ymm6;vaddps %ymm6,%ymm7,%ymm0;vaddps %ymm0,%ymm1,%ymm2;vmulps %ymm2,%ymm3,%ymm4;vdivps %ymm4,%ymm5,%ymm6;vaddps %ymm6,%ymm7,%ymm1;jmp .continue;.phase1:imul %rax,%rbx;add %rbx,%rcx;xor %rcx,%rdx;ror $11,%rax;imul %rdx,%rax;add %rax,%rbx;xor %rbx,%rcx;ror $13,%rdx;imul %rcx,%rdx;jmp .continue;.phase2:test $1,%r14;jz .bp1;test $2,%r14;jnz .bp2;test $4,%r14;jz .bp3;test $8,%r14;jnz .bp4;jmp .branch_done;.bp1:add $1,%rax;jmp .branch_done;.bp2:sub $1,%rbx;jmp .branch_done;.bp3:xor $0xFF,%rcx;jmp .branch_done;.bp4:rol $1,%rdx;.branch_done:jmp .continue;.phase3:push %rax;push %rbx;push %rcx;push %rdx;add (%rsp),%rax;xor 8(%rsp),%rbx;sub 16(%rsp),%rcx;pop %rdx;pop %rcx;pop %rbx;pop %rax;.continue:test $0xFFFFF,%r14;jnz .main_loop;cmp %r13,%r14;jl .main_loop;.exit:mov $60,%rax;xor %rdi,%rdi;syscall
SPEC_HAVOC_EOF
    as spec_havoc.S -o spec_havoc.o && ld spec_havoc.o -o spec_havoc || { log_message "!!! Spec Havoc assembly/linking failed!"; return 1; }
    log_message "[+] Spec Havoc compilation successful."; return 0
}

# =============================================================
#               INITIAL SETUP & BASELINE
# =============================================================
log_message "=== Advanced NS-RAM System Analogy Stress Test v2.3 ==="
log_message "Start time: $(date)"
log_message "!!! EXTREME WARNING: DANGEROUS & EXPERIMENTAL SCRIPT !!!"
log_message "Mode: $MODE"
cpu_model=$(lscpu | grep 'Model name' | sed 's/Model name:[[:space:]]*//' || echo "Unknown CPU")
log_message "CPU: $cpu_model"; log_message "Kernel: $(uname -r)"
log_message "[*] Initial system configuration..."
if command -v cpupower &>/dev/null; then (set +e; cpupower frequency-set -g performance || log_message "WARN: Failed to set performance governor.")
else log_message "WARN: cpupower not found, skipping governor setting."; fi
if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then (set +e; echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo || log_message "WARN: Failed to disable intel_pstate turbo")
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then (set +e; echo 0 > /sys/devices/system/cpu/cpufreq/boost || log_message "WARN: Failed to disable cpufreq boost")
else log_message "[*] WARN: Could not find standard interface to disable Turbo Boost."; fi
if [ -f /proc/sys/kernel/randomize_va_space ]; then (set +e; echo 0 > /proc/sys/kernel/randomize_va_space || log_message "WARN: Failed to disable ASLR"); fi
set_rapl_limit 
log_message "[*] Compiling custom stress tools..."
compile_hammer || log_message "[WARN] Hammer tool compilation failed, some tests might be affected."
compile_spec_havoc || log_message "[WARN] Spec Havoc tool compilation failed, some tests might be affected."

log_message "[1] CAPTURING SYSTEM BASELINE"; sleep 1 
baseline_freq=$(get_cpu_freq); baseline_temp=$(get_cpu_temp)
log_message "  Initial frequency: ${baseline_freq} KHz, Initial temp: ${baseline_temp} C"
log_message "  Running Baseline Performance (Sysbench with Perf)..."
all_baseline_perf_results=$(run_perf_and_sysbench)
baseline_bench_score=$(echo "$all_baseline_perf_results" | cut -d, -f1)
baseline_ipc=$(echo "$all_baseline_perf_results" | cut -d, -f2)
baseline_l1d_misses=$(echo "$all_baseline_perf_results" | cut -d, -f3)
baseline_llc_misses=$(echo "$all_baseline_perf_results" | cut -d, -f4)
baseline_branch_misses=$(echo "$all_baseline_perf_results" | cut -d, -f5)
log_message "  Baseline Sysbench CPU Score: ${baseline_bench_score:-N/A} events/sec"
log_message "  Baseline Perf: IPC=${baseline_ipc:-N/A}, L1D=${baseline_l1d_misses:-N/A}, LLC=${baseline_llc_misses:-N/A}, Branch=${baseline_branch_misses:-N/A}"
log_message "  Running Baseline Memory Bandwidth (mbw)..."
baseline_mbw_score=$(run_mbw); log_message "  Baseline MBW Score: ${baseline_mbw_score:-N/A} MB/s"
log_message "  Getting Baseline ECC Errors..."
all_baseline_ecc_results=$(get_ecc_errors)
baseline_ecc_ce=$(echo "$all_baseline_ecc_results" | cut -d, -f1)
baseline_ecc_ue=$(echo "$all_baseline_ecc_results" | cut -d, -f2)
log_message "  Baseline ECC: CE=${baseline_ecc_ce:-N/A}, UE=${baseline_ecc_ue:-N/A}"
log_message "[*] Generating test data ($DATA_SIZE_MB MB)..."
dd if=/dev/urandom of="$TEST_DATA_FILE" bs=1M count=$DATA_SIZE_MB status=none conv=fsync
md5_orig=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Original data hash (MD5): $md5_orig"
sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)

# =============================================================
#                    MODE: NEURON (LIF Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "NEURON" ]; then
    log_message "\n[2] NEURON MODE TEST (LIF Analogy)"
    failed_integrate=false # No local here
    for cycle in $(seq 1 $NEURON_CYCLES); do
        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Applying Pulse (τon)..."
        temp_before_pulse=$(get_cpu_temp) # No local
        apply_stress "$NEURON_PULSE_AMPLITUDE" "$NEURON_PULSE_INTERVAL_ON_S" & stress_pid=$!
        if [ -x "./spec_havoc" ]; then timeout "${NEURON_PULSE_INTERVAL_ON_S}s" ./spec_havoc &>/dev/null & havoc_pid=$!; fi
        wait $stress_pid 2>/dev/null; [ -n "${havoc_pid:-}" ] && { kill $havoc_pid 2>/dev/null || true; wait $havoc_pid 2>/dev/null || true; unset havoc_pid;}
        temp_after_pulse=$(get_cpu_temp); freq_after_pulse=$(get_cpu_freq)
        
        perf_pulse_results=$(run_perf_and_sysbench) # No local
        pulse_ipc=$(echo "$perf_pulse_results" | cut -d, -f2); pulse_l1d=$(echo "$perf_pulse_results" | cut -d, -f3) # No local
        pulse_llc=$(echo "$perf_pulse_results" | cut -d, -f4); pulse_branch=$(echo "$perf_pulse_results" | cut -d, -f5) # No local
        pulse_mbw=$(run_mbw) # No local
        ecc_pulse_results=$(get_ecc_errors) # No local
        pulse_ecc_ce=$(echo "$ecc_pulse_results" | cut -d, -f1); pulse_ecc_ue=$(echo "$ecc_pulse_results" | cut -d, -f2) # No local

        log_message "  Pulse End: Temp=${temp_after_pulse}C, Freq=${freq_after_pulse}KHz, IPC=${pulse_ipc:-N/A}, MBW=${pulse_mbw:-N/A}"
        error_detected=0; if dmesg | tail -n 50 | grep -q -iE 'MCE|uncorrected|critical|panic'; then error_detected=1; failed_integrate=true; fi
        save_neuron_data "$cycle" "pulse" "$temp_after_pulse" "$freq_after_pulse" "N/A" "$error_detected" \
                         "${pulse_ipc:-N/A}" "${pulse_l1d:-N/A}" "${pulse_llc:-N/A}" "${pulse_branch:-N/A}" "${pulse_mbw:-N/A}" "${pulse_ecc_ce:-N/A}" "${pulse_ecc_ue:-N/A}"
        if [ "$failed_integrate" = true ]; then break; fi

        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Recovery phase (τoff - Leaking)..."
        time_start_recovery=$(date +%s.%N); sleep "$NEURON_PULSE_INTERVAL_OFF_S"; time_end_recovery=$(date +%s.%N)
        temp_after_recovery=$(get_cpu_temp); freq_after_recovery=$(get_cpu_freq)
        recovery_duration=$(echo "$time_end_recovery - $time_start_recovery" | bc) # No local
        
        perf_rec_results=$(run_perf_and_sysbench) # No local
        rec_ipc=$(echo "$perf_rec_results" | cut -d, -f2); rec_l1d=$(echo "$perf_rec_results" | cut -d, -f3) # No local
        rec_llc=$(echo "$perf_rec_results" | cut -d, -f4); rec_branch=$(echo "$perf_rec_results" | cut -d, -f5) # No local
        rec_mbw=$(run_mbw) # No local
        ecc_rec_results=$(get_ecc_errors) # No local
        rec_ecc_ce=$(echo "$ecc_rec_results" | cut -d, -f1); rec_ecc_ue=$(echo "$ecc_rec_results" | cut -d, -f2) # No local

        log_message "  Recovery End: Temp=${temp_after_recovery}C, Freq=${freq_after_recovery}KHz, IPC=${rec_ipc:-N/A}, MBW=${rec_mbw:-N/A}"
        save_neuron_data "$cycle" "recovery" "$temp_after_recovery" "$freq_after_recovery" "$recovery_duration" "0" \
                         "${rec_ipc:-N/A}" "${rec_l1d:-N/A}" "${rec_llc:-N/A}" "${rec_branch:-N/A}" "${rec_mbw:-N/A}" "${rec_ecc_ce:-N/A}" "${rec_ecc_ue:-N/A}"
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
        sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)
        
        perf_st_start_results=$(run_perf_and_sysbench) # No local
        cycle_start_score=$(echo "$perf_st_start_results" | cut -d, -f1); cycle_start_ipc=$(echo "$perf_st_start_results" | cut -d, -f2) # No local
        cycle_start_l1d=$(echo "$perf_st_start_results" | cut -d, -f3); cycle_start_llc=$(echo "$perf_st_start_results" | cut -d, -f4) # No local
        cycle_start_branch=$(echo "$perf_st_start_results" | cut -d, -f5); cycle_start_mbw=$(run_mbw) # No local
        ecc_st_start_results=$(get_ecc_errors); cycle_start_ecc_ce=$(echo "$ecc_st_start_results" | cut -d, -f1); cycle_start_ecc_ue=$(echo "$ecc_st_start_results" | cut -d, -f2) # No local
        save_synaptic_short_data "$cycle" "start" "0" "${cycle_start_score:-N/A}" "${cycle_start_ipc:-N/A}" "${cycle_start_l1d:-N/A}" "${cycle_start_llc:-N/A}" "${cycle_start_branch:-N/A}" "${cycle_start_mbw:-N/A}" "${cycle_start_ecc_ce:-N/A}" "${cycle_start_ecc_ue:-N/A}"

        for p_pulse in $(seq 1 $SYN_ST_POT_PULSES); do
            log_message "  Potentiation Pulse $p_pulse/$SYN_ST_POT_PULSES..."
            if [ -x "./hammer" ]; then ./hammer --reps "$HAMMER_ITERATIONS" --pattern-length "$HAMMER_PATTERN_LENGTH" --perform-write "$HAMMER_WRITE_OPS" --thread-count "$HAMMER_THREAD_COUNT" --access-pattern "$HAMMER_ACCESS_PATTERN" --cache-flush "$HAMMER_CACHE_FLUSH" --verbose 0 &>/dev/null & hammer_pid=$!; fi
            apply_stress "$SYN_ST_POTENTIATION_LOAD" "$SYN_ST_PULSE_DURATION_S"
            [ -n "${hammer_pid:-}" ] && { kill $hammer_pid 2>/dev/null || true; wait $hammer_pid 2>/dev/null || true; unset hammer_pid; }
            sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)

            perf_st_pot_results=$(run_perf_and_sysbench); pot_score=$(echo "$perf_st_pot_results" | cut -d, -f1) # No local
            pot_ipc=$(echo "$perf_st_pot_results" | cut -d, -f2); pot_l1d=$(echo "$perf_st_pot_results" | cut -d, -f3); pot_llc=$(echo "$perf_st_pot_results" | cut -d, -f4); pot_branch=$(echo "$perf_st_pot_results" | cut -d, -f5) # No local
            pot_mbw=$(run_mbw); ecc_st_pot_results=$(get_ecc_errors); pot_ecc_ce=$(echo "$ecc_st_pot_results" | cut -d, -f1); pot_ecc_ue=$(echo "$ecc_st_pot_results" | cut -d, -f2) # No local
            save_synaptic_short_data "$cycle" "potentiation" "$p_pulse" "${pot_score:-N/A}" "${pot_ipc:-N/A}" "${pot_l1d:-N/A}" "${pot_llc:-N/A}" "${pot_branch:-N/A}" "${pot_mbw:-N/A}" "${pot_ecc_ce:-N/A}" "${pot_ecc_ue:-N/A}"
        done

        for d_pulse in $(seq 1 $SYN_ST_DEP_PULSES); do
            log_message "  Depression Pulse $d_pulse/$SYN_ST_DEP_PULSES..."
            apply_stress "$SYN_ST_DEPRESSION_LOAD" "$SYN_ST_PULSE_DURATION_S" 
            sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)
            
            perf_st_dep_results=$(run_perf_and_sysbench); dep_score=$(echo "$perf_st_dep_results" | cut -d, -f1) # No local
            dep_ipc=$(echo "$perf_st_dep_results" | cut -d, -f2); dep_l1d=$(echo "$perf_st_dep_results" | cut -d, -f3); dep_llc=$(echo "$perf_st_dep_results" | cut -d, -f4); dep_branch=$(echo "$perf_st_dep_results" | cut -d, -f5) # No local
            dep_mbw=$(run_mbw); ecc_st_dep_results=$(get_ecc_errors); dep_ecc_ce=$(echo "$ecc_st_dep_results" | cut -d, -f1); dep_ecc_ue=$(echo "$ecc_st_dep_results" | cut -d, -f2) # No local
            save_synaptic_short_data "$cycle" "depression" "$d_pulse" "${dep_score:-N/A}" "${dep_ipc:-N/A}" "${dep_l1d:-N/A}" "${dep_llc:-N/A}" "${dep_branch:-N/A}" "${dep_mbw:-N/A}" "${dep_ecc_ce:-N/A}" "${dep_ecc_ue:-N/A}"
        done
        
        log_message "  Forgetting/Relaxation Phase (${SYN_ST_FORGET_DURATION_S}s)..."
        time_start_forget=$(date +%s) # No local
        while true; do
            current_time_forget=$(date +%s); elapsed_forget=$(( current_time_forget - time_start_forget )) # No local
            if [ $elapsed_forget -ge $SYN_ST_FORGET_DURATION_S ]; then break; fi
            if (( elapsed_forget % 5 == 0 )); then 
                 sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)
                 perf_st_forget_results=$(run_perf_and_sysbench); forget_score=$(echo "$perf_st_forget_results" | cut -d, -f1) # No local
                 forget_ipc=$(echo "$perf_st_forget_results" | cut -d, -f2); forget_l1d=$(echo "$perf_st_forget_results" | cut -d, -f3); forget_llc=$(echo "$perf_st_forget_results" | cut -d, -f4); forget_branch=$(echo "$perf_st_forget_results" | cut -d, -f5) # No local
                 forget_mbw=$(run_mbw); ecc_st_forget_results=$(get_ecc_errors); forget_ecc_ce=$(echo "$ecc_st_forget_results" | cut -d, -f1); forget_ecc_ue=$(echo "$ecc_st_forget_results" | cut -d, -f2) # No local
                 save_synaptic_short_data "$cycle" "forget" "$elapsed_forget" "${forget_score:-N/A}" "${forget_ipc:-N/A}" "${forget_l1d:-N/A}" "${forget_llc:-N/A}" "${forget_branch:-N/A}" "${forget_mbw:-N/A}" "${forget_ecc_ce:-N/A}" "${forget_ecc_ue:-N/A}"
            fi; sleep 1
        done
        log_message "  Forgetting phase complete."
    done
    log_message "[✓] SYNAPSE SHORT-TERM MODE COMPLETED."
fi

if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_LONG" ]; then
    log_message "\n[4] SYNAPSE MODE TEST (Long-Term Plasticity Analogy)"
    ltp_errors=false; ltp_corruption=false # No local
    for cycle in $(seq 1 $SYN_LT_CYCLES); do
        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Potentiation..."
        temp_before_ltp_pot=$(get_cpu_temp) # No local
        if [ -x "./hammer" ] && [ $((cycle % 2 == 0)) -eq 0 ]; then 
             ./hammer --reps "$HAMMER_ITERATIONS" --pattern-length "$HAMMER_PATTERN_LENGTH" --perform-write "$HAMMER_WRITE_OPS" --thread-count "$HAMMER_THREAD_COUNT" --access-pattern "$HAMMER_ACCESS_PATTERN" --cache-flush "$HAMMER_CACHE_FLUSH" --verbose 0 &>/dev/null & hammer_pid=$!
        fi
        apply_stress "$SYN_LT_POTENTIATION_LOAD" "$SYN_LT_PULSE_DURATION_S"
        [ -n "${hammer_pid:-}" ] && { kill $hammer_pid 2>/dev/null || true; wait $hammer_pid 2>/dev/null || true; unset hammer_pid; }
        sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)

        perf_lt_pot_results=$(run_perf_and_sysbench); ltp_pot_score=$(echo "$perf_lt_pot_results" | cut -d, -f1) # No local
        ltp_pot_ipc=$(echo "$perf_lt_pot_results" | cut -d, -f2); ltp_pot_l1d=$(echo "$perf_lt_pot_results" | cut -d, -f3); ltp_pot_llc=$(echo "$perf_lt_pot_results" | cut -d, -f4); ltp_pot_branch=$(echo "$perf_lt_pot_results" | cut -d, -f5) # No local
        ltp_pot_mbw=$(run_mbw); ecc_lt_pot_results=$(get_ecc_errors); ltp_pot_ecc_ce=$(echo "$ecc_lt_pot_results" | cut -d, -f1); ltp_pot_ecc_ue=$(echo "$ecc_lt_pot_results" | cut -d, -f2) # No local
        temp_after_ltp_pot=$(get_cpu_temp) # No local
        save_synaptic_long_data "$cycle" "potentiation" "$temp_after_ltp_pot" "${ltp_pot_score:-N/A}" "0" "0" \
                                "${ltp_pot_ipc:-N/A}" "${ltp_pot_l1d:-N/A}" "${ltp_pot_llc:-N/A}" "${ltp_pot_branch:-N/A}" "${ltp_pot_mbw:-N/A}" "${ltp_pot_ecc_ce:-N/A}" "${ltp_pot_ecc_ue:-N/A}"

        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Depression..."
        apply_stress "$SYN_LT_DEPRESSION_LOAD" "$SYN_LT_PULSE_DURATION_S" 
        sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)

        perf_lt_dep_results=$(run_perf_and_sysbench); ltp_dep_score=$(echo "$perf_lt_dep_results" | cut -d, -f1) # No local
        ltp_dep_ipc=$(echo "$perf_lt_dep_results" | cut -d, -f2); ltp_dep_l1d=$(echo "$perf_lt_dep_results" | cut -d, -f3); ltp_dep_llc=$(echo "$perf_lt_dep_results" | cut -d, -f4); ltp_dep_branch=$(echo "$perf_lt_dep_results" | cut -d, -f5) # No local
        ltp_dep_mbw=$(run_mbw); ecc_lt_dep_results=$(get_ecc_errors); ltp_dep_ecc_ce=$(echo "$ecc_lt_dep_results" | cut -d, -f1); ltp_dep_ecc_ue=$(echo "$ecc_lt_dep_results" | cut -d, -f2) # No local
        temp_after_ltp_dep=$(get_cpu_temp) # No local
        
        error_detected_ltp=0; corruption_detected_ltp=0 # No local
        if dmesg | tail -n 20 | grep -q -iE 'MCE|uncorrected|critical|panic'; then error_detected_ltp=1; ltp_errors=true; fi
        if (( cycle % 5 == 0 || cycle == SYN_LT_CYCLES )); then sync; md5_now=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}'); if [ "$md5_orig" != "$md5_now" ]; then corruption_detected_ltp=1; ltp_corruption=true; fi; fi
        save_synaptic_long_data "$cycle" "depression" "$temp_after_ltp_dep" "${ltp_dep_score:-N/A}" "$error_detected_ltp" "$corruption_detected_ltp" \
                                "${ltp_dep_ipc:-N/A}" "${ltp_dep_l1d:-N/A}" "${ltp_dep_llc:-N/A}" "${ltp_dep_branch:-N/A}" "${ltp_dep_mbw:-N/A}" "${ltp_dep_ecc_ce:-N/A}" "${ltp_dep_ecc_ue:-N/A}"
        if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then break; fi
        if [ $SYN_LT_CYCLES -ge 5 ] && [ $((cycle % (SYN_LT_CYCLES / 5 ))) -eq 0 ] && [ $cycle -ne 0 ]; then log_message "  LTP Cycle $cycle/$SYN_LT_CYCLES completed."; 
        elif [ $cycle -eq $SYN_LT_CYCLES ]; then log_message "  LTP Cycle $cycle/$SYN_LT_CYCLES completed."; fi # Log last cycle if not caught by modulo
    done

    if [ "$ltp_errors" = false ] && [ "$ltp_corruption" = false ]; then
        log_message "LTP Cycling complete. Starting Retention Test (${SYN_LT_RETENTION_S}s)..."
        sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)

        perf_lt_ret_start_results=$(run_perf_and_sysbench); ret_start_score=$(echo "$perf_lt_ret_start_results" | cut -d, -f1) # No local
        ret_start_ipc=$(echo "$perf_lt_ret_start_results" | cut -d, -f2); ret_start_l1d=$(echo "$perf_lt_ret_start_results" | cut -d, -f3); ret_start_llc=$(echo "$perf_lt_ret_start_results" | cut -d, -f4); ret_start_branch=$(echo "$perf_lt_ret_start_results" | cut -d, -f5) # No local
        ret_start_mbw=$(run_mbw); ecc_lt_ret_start_results=$(get_ecc_errors); ret_start_ecc_ce=$(echo "$ecc_lt_ret_start_results" | cut -d, -f1); ret_start_ecc_ue=$(echo "$ecc_lt_ret_start_results" | cut -d, -f2) # No local
        ret_start_temp=$(get_cpu_temp) # No local
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_start" "$ret_start_temp" "${ret_start_score:-N/A}" "0" "0" \
                                "${ret_start_ipc:-N/A}" "${ret_start_l1d:-N/A}" "${ret_start_llc:-N/A}" "${ret_start_branch:-N/A}" "${ret_start_mbw:-N/A}" "${ret_start_ecc_ce:-N/A}" "${ret_start_ecc_ue:-N/A}"
        
        time_start_retention=$(date +%s) # No local
        while true; do
            current_time_ret=$(date +%s); elapsed_ret=$(( current_time_ret - time_start_retention )) # No local
            if [ $elapsed_ret -ge $SYN_LT_RETENTION_S ]; then break; fi
            if (( elapsed_ret % 10 == 0 && elapsed_ret > 0 )); then 
                 sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)
                 perf_lt_ret_prog_results=$(run_perf_and_sysbench); ret_prog_score=$(echo "$perf_lt_ret_prog_results" | cut -d, -f1) # No local
                 ret_prog_ipc=$(echo "$perf_lt_ret_prog_results" | cut -d, -f2); ret_prog_l1d=$(echo "$perf_lt_ret_prog_results" | cut -d, -f3); ret_prog_llc=$(echo "$perf_lt_ret_prog_results" | cut -d, -f4); ret_prog_branch=$(echo "$perf_lt_ret_prog_results" | cut -d, -f5) # No local
                 ret_prog_mbw=$(run_mbw); ecc_lt_ret_prog_results=$(get_ecc_errors); ret_prog_ecc_ce=$(echo "$ecc_lt_ret_prog_results" | cut -d, -f1); ret_prog_ecc_ue=$(echo "$ecc_lt_ret_prog_results" | cut -d, -f2) # No local
                 ret_prog_temp=$(get_cpu_temp) # No local
                 save_synaptic_long_data "$SYN_LT_CYCLES" "retention_progress" "$ret_prog_temp" "${ret_prog_score:-N/A}" "0" "0" \
                                         "${ret_prog_ipc:-N/A}" "${ret_prog_l1d:-N/A}" "${ret_prog_llc:-N/A}" "${ret_prog_branch:-N/A}" "${ret_prog_mbw:-N/A}" "${ret_prog_ecc_ce:-N/A}" "${ret_prog_ecc_ue:-N/A}"
            fi; sleep 1
        done
        log_message "Retention Test: Final Checks..."
        sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true)
        
        perf_lt_final_results=$(run_perf_and_sysbench); local final_ltp_score; final_ltp_score=$(echo "$perf_lt_final_results" | cut -d, -f1) # No local (final_ltp_score is fine as it's used immediately)
        local final_ltp_ipc; final_ltp_ipc=$(echo "$perf_lt_final_results" | cut -d, -f2); local final_ltp_l1d_misses; final_ltp_l1d_misses=$(echo "$perf_lt_final_results" | cut -d, -f3)
        local final_ltp_llc_misses; final_ltp_llc_misses=$(echo "$perf_lt_final_results" | cut -d, -f4); local final_ltp_branch_misses; final_ltp_branch_misses=$(echo "$perf_lt_final_results" | cut -d, -f5)
        local final_ltp_mbw_score; final_ltp_mbw_score=$(run_mbw)
        local ecc_lt_final_results; ecc_lt_final_results=$(get_ecc_errors)
        local final_ltp_ecc_ce; final_ltp_ecc_ce=$(echo "$ecc_lt_final_results" | cut -d, -f1); local final_ltp_ecc_ue; final_ltp_ecc_ue=$(echo "$ecc_lt_final_results" | cut -d, -f2)
        local final_ltp_temp; final_ltp_temp=$(get_cpu_temp)

        local error_final_ltp=0; local corruption_final_ltp=0 # These are fine, no `local` needed at top-level scope of loop
        md5_after_retention=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
        if [ "$md5_orig" != "$md5_after_retention" ]; then corruption_final_ltp=1; ltp_corruption=true; fi
        if dmesg | tail -n 100 | grep -q -iE 'MCE|uncorrected|critical|panic'; then error_final_ltp=1; ltp_errors=true; fi
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_end" "$final_ltp_temp" "${final_ltp_score:-N/A}" "$error_final_ltp" "$corruption_final_ltp" \
                                "${final_ltp_ipc:-N/A}" "${final_ltp_l1d_misses:-N/A}" "${final_ltp_llc_misses:-N/A}" "${final_ltp_branch_misses:-N/A}" "${final_ltp_mbw_score:-N/A}" "${final_ltp_ecc_ce:-N/A}" "${final_ltp_ecc_ue:-N/A}"
    fi
    log_message "[$(if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then echo "!!! LTP MODE FAILED"; else echo "✓ LTP MODE COMPLETED"; fi)]"
fi

# =============================================================
#                   FINAL ANALYSIS & VERDICT
# =============================================================
log_message "\n[5] FINAL SYSTEM STATE & OVERALL EVALUATION"
sleep 1; sync; (set +e; echo 3 > /proc/sys/vm/drop_caches || true) 
final_freq=$(get_cpu_freq); final_temp=$(get_cpu_temp)
all_final_perf_results=$(run_perf_and_sysbench)
final_bench_score=$(echo "$all_final_perf_results" | cut -d, -f1)
final_ipc=$(echo "$all_final_perf_results" | cut -d, -f2)
final_l1d_misses=$(echo "$all_final_perf_results" | cut -d, -f3)
final_llc_misses=$(echo "$all_final_perf_results" | cut -d, -f4)
final_branch_misses=$(echo "$all_final_perf_results" | cut -d, -f5)
final_mbw_score=$(run_mbw)
all_final_ecc_results=$(get_ecc_errors)
final_ecc_ce=$(echo "$all_final_ecc_results" | cut -d, -f1)
final_ecc_ue=$(echo "$all_final_ecc_results" | cut -d, -f2)

log_message "Final frequency: ${final_freq:-N/A} KHz (Baseline: ${baseline_freq:-N/A} KHz)"
log_message "Final temp: ${final_temp:-N/A} C (Baseline: ${baseline_temp:-N/A} C)"
log_message "Final Sysbench Score: ${final_bench_score:-N/A} (Baseline: ${baseline_bench_score:-N/A})"
log_message "Final IPC: ${final_ipc:-N/A} (Baseline: ${baseline_ipc:-N/A})"
log_message "Final L1D Misses: ${final_l1d_misses:-N/A} (Baseline: ${baseline_l1d_misses:-N/A})"
log_message "Final LLC Misses: ${final_llc_misses:-N/A} (Baseline: ${baseline_llc_misses:-N/A})"
log_message "Final Branch Misses: ${final_branch_misses:-N/A} (Baseline: ${baseline_branch_misses:-N/A})"
log_message "Final MBW Score: ${final_mbw_score:-N/A} MB/s (Baseline: ${baseline_mbw_score:-N/A})"
log_message "Final ECC CE: ${final_ecc_ce:-N/A} (Baseline: ${baseline_ecc_ce:-N/A})"
log_message "Final ECC UE: ${final_ecc_ue:-N/A} (Baseline: ${baseline_ecc_ue:-N/A})"

final_md5=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Final MD5 Check: $final_md5 (Original: $md5_orig)"
if [ "$md5_orig" != "$final_md5" ]; then log_message "[!!!] OVERALL DATA CORRUPTION DETECTED!"; fi
save_system_summary 

{
    echo "MODE=$MODE"; echo "TOTAL_DURATION_S=$TOTAL_DURATION_S"
    echo "NEURON_CYCLES=$NEURON_CYCLES"; echo "NEURON_PULSE_AMPLITUDE=$NEURON_PULSE_AMPLITUDE"
    echo "NEURON_PULSE_INTERVAL_ON_S=$NEURON_PULSE_INTERVAL_ON_S"; echo "NEURON_PULSE_INTERVAL_OFF_S=$NEURON_PULSE_INTERVAL_OFF_S"
    echo "SYN_ST_POTENTIATION_LOAD=$SYN_ST_POTENTIATION_LOAD"; echo "SYN_ST_DEPRESSION_LOAD=$SYN_ST_DEPRESSION_LOAD"
    echo "SYN_ST_PULSE_DURATION_S=$SYN_ST_PULSE_DURATION_S"; echo "SYN_ST_POT_PULSES=$SYN_ST_POT_PULSES"
    echo "SYN_ST_DEP_PULSES=$SYN_ST_DEP_PULSES"; echo "SYN_ST_FORGET_DURATION_S=$SYN_ST_FORGET_DURATION_S"
    echo "SYN_ST_CYCLES=$SYN_ST_CYCLES"
    echo "SYN_LT_POTENTIATION_LOAD=$SYN_LT_POTENTIATION_LOAD"; echo "SYN_LT_DEPRESSION_LOAD=$SYN_LT_DEPRESSION_LOAD"
    echo "SYN_LT_PULSE_DURATION_S=$SYN_LT_PULSE_DURATION_S"; echo "SYN_LT_CYCLES=$SYN_LT_CYCLES"; echo "SYN_LT_RETENTION_S=$SYN_LT_RETENTION_S"
    echo "USE_RAPL=$USE_RAPL"; echo "RAPL_POWER_LIMIT_W=$RAPL_POWER_LIMIT_W"
    echo "HAMMER_ITERATIONS=$HAMMER_ITERATIONS"; echo "HAMMER_PATTERN_LENGTH=$HAMMER_PATTERN_LENGTH"
    echo "HAMMER_WRITE_OPS=$HAMMER_WRITE_OPS"; echo "HAMMER_THREAD_COUNT=$HAMMER_THREAD_COUNT"
    echo "HAMMER_ACCESS_PATTERN=$HAMMER_ACCESS_PATTERN"; echo "HAMMER_CACHE_FLUSH=$HAMMER_CACHE_FLUSH"
    echo "CPU_MODEL=\"$cpu_model\""; echo "KERNEL_VERSION=$(uname -r)"
} > "${DATA_DIR}/test_config.txt"

overall_verdict_msg=""
if grep -q -iE 'MCE|uncorrected|critical|panic|CORRUPTION DETECTED|MODE FAILED' "$LOGFILE"; then
    overall_verdict_msg="❌ SYSTEM FAILURE: Critical errors, data corruption or mode failure occurred. NS-RAM Analog: Device threshold exceeded, resulting in irreversible state change or damage."
elif grep -q 'WARN:' "$LOGFILE"; then
    overall_verdict_msg="⚠️  SYSTEM STRESSED BUT STABLE: Tests completed without critical failures, but with warnings. NS-RAM Analog: Device operated near threshold, showing stress effects but no permanent failure."
else
    overall_verdict_msg="✅ SYSTEM RESILIENT: Completed all tests successfully with strong recovery. NS-RAM Analog: Device operated within robust operating region, maintaining state integrity."
fi
log_message "\n--- OVERALL VERDICT (NS-RAM Analogy Interpretation) ---"; log_message "$overall_verdict_msg"
log_message "Test completed at: $(date)"; log_message "Log file saved to: $LOGFILE"
log_message "Data directory for plotting: $DATA_DIR (contains CSVs and temp_perf_output.txt)"
log_message "Review $TEMP_PERF_FILE for detailed perf stat outputs if needed."

if [ "$_PRELIM_LOG_USED" -eq 1 ] && [ -f "$LOGFILE_PRELIM" ] && [ "$LOGFILE_PRELIM" != "$LOGFILE" ]; then
    cat "$LOGFILE_PRELIM" >> "$LOGFILE"; rm -f "$LOGFILE_PRELIM"; fi
exit 0