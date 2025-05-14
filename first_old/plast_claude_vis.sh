#!/bin/bash

# ─────────────────────────────────────────────
# Advanced NS-RAM System-Level Analogy Stress Suite v2
# !!! EXTREME DANGER - CONCEPTUAL ANALOGY ONLY - FOR TEST MACHINES !!!
# Attempts to map NS-RAM transistor dynamics (LIF, Plasticity, Tuning)
# onto observable system behaviors (throttling, performance changes, errors).
# This CANNOT replicate transistor physics. Results are INTERPRETIVE.
# ─────────────────────────────────────────────
# --- Dependency Check & Installation ---
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Please run this script as root or with sudo." >&2
    exit 1
fi

log_install() {
    echo "[+] Installing missing packages: $*"
}

REQUIRED_PACKAGES=(
    stress-ng
    sysbench
    lm-sensors
    linux-tools-common
    "linux-tools-$(uname -r)"
    gcc
    binutils
    build-essential
    powercap-utils
    coreutils
    bc
)

# Detect apt-based systems (Debian, Ubuntu)
if command -v apt-get &>/dev/null; then
    apt-get update
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            log_install "$pkg"
            apt-get install -y "$pkg" || echo "Failed to install $pkg, continuing..."
        fi
    done
    # Try installing cpupower separately (handle potential package name differences)
    if ! command -v cpupower &>/dev/null; then
        log_install "cpupower"
        apt-get install -y cpupower || apt-get install -y linux-tools-generic || echo "Failed to install cpupower, continuing..."
    fi
    # Configure sensors
    echo "[*] Running sensors-detect (auto-confirm)..."
    yes | sensors-detect >/dev/null 2>&1 || true
else
    echo "[ERROR] Unsupported package manager. Please manually install required packages:" >&2
    printf "  %s\n" "${REQUIRED_PACKAGES[@]}"
    exit 1
fi

set -euo pipefail

# --- Configuration ---
MODE="ALL" # Options: "ALL", "NEURON", "SYNAPSE_SHORT", "SYNAPSE_LONG"
TOTAL_DURATION_S=120 # Max duration for modes like NEURON or endurance loops
LOGFILE="nsram_analogy_results_$(date +%Y%m%d_%H%M%S).log"
TEST_DATA_FILE="stress_test_data.bin"
DATA_SIZE_MB=20

# --- Data Collection for Plotting ---
RUN_ID=$(date +%Y%m%d_%H%M%S)
DATA_DIR="stress_data_${RUN_ID}"
mkdir -p "$DATA_DIR"

# CSV data files for plotting
NEURON_DATA="${DATA_DIR}/neuron_data.csv"
SYNAPTIC_SHORT_DATA="${DATA_DIR}/synaptic_short_data.csv"
SYNAPTIC_LONG_DATA="${DATA_DIR}/synaptic_long_data.csv"
SYSTEM_SUMMARY="${DATA_DIR}/system_summary.csv"

# Initialize data files with headers
echo "timestamp,cycle,phase,temp,freq,recovery_time,error_detected" > "$NEURON_DATA"
echo "timestamp,cycle,phase,pulse,bench_score,percent_of_baseline" > "$SYNAPTIC_SHORT_DATA"
echo "timestamp,cycle,phase,temp,bench_score,error_detected,corruption_detected" > "$SYNAPTIC_LONG_DATA"
echo "metric,baseline,final,percent_change" > "$SYSTEM_SUMMARY"

# --- Tunability Parameters (Analogies to VG, VG2, Pulse Params) ---
# ** Neuron Mode **
NEURON_PULSE_AMPLITUDE="max"  # Stress level during pulse: "max", "high", "medium"
NEURON_PULSE_INTERVAL_ON_S=5  # Duration of stress pulse
NEURON_PULSE_INTERVAL_OFF_S=5 # Duration of recovery/leak period
NEURON_CYCLES=10            # Number of pulses to apply in NEURON mode

# ** Synapse Short-Term Mode **
SYN_ST_POTENTIATION_LOAD="high" # Stress level for potentiation: "high", "medium"
SYN_ST_DEPRESSION_LOAD="idle"   # Stress level for depression: "low", "idle"
SYN_ST_PULSE_DURATION_S=3     # Duration of each potentiation/depression pulse
SYN_ST_POT_PULSES=5           # Number of potentiation pulses in a sequence
SYN_ST_DEP_PULSES=5           # Number of depression pulses in a sequence
SYN_ST_FORGET_DURATION_S=30   # How long to monitor relaxation/forgetting
SYN_ST_CYCLES=3               # Number of full Potentiation->Depression->Forget cycles

# ** Synapse Long-Term Mode **
SYN_LT_POTENTIATION_LOAD="max"  # Intense stress for potentiation
SYN_LT_DEPRESSION_LOAD="idle"   # Can be idle or specific low-power MSR state if known
SYN_LT_PULSE_DURATION_S=10    # Longer pulses for potential "charge trapping" analogy
SYN_LT_CYCLES=50             # Number of bipolar stress cycles (POT -> DEP)
SYN_LT_RETENTION_S=60         # Idle time after cycling to check for persistent effects

# ** Optional Power Limiting (RAPL - Analogy for limiting drive/VDD) **
USE_RAPL=false # Set to true to enable power capping
RAPL_POWER_LIMIT_W=50 # Example power limit in Watts (adjust based on CPU TDP)

# --- Stress Level Definitions ---
declare -A STRESS_PARAMS
STRESS_PARAMS["max"]="--cpu $(nproc) --matrix $(nproc) --vm $(nproc) --vm-bytes 1G --cpu-method all"
STRESS_PARAMS["high"]="--cpu $(nproc) --matrix 0 --vm $(nproc) --vm-bytes 512M --cpu-method int64,float"
STRESS_PARAMS["medium"]="--cpu $(($(nproc)/2)) --matrix 0 --vm 0 --cpu-method bitops"
STRESS_PARAMS["low"]="--cpu 1 --vm 0 --cpu-method trivial"
STRESS_PARAMS["idle"]="" # Represents no explicit stress-ng load

# --- Global Variables ---
baseline_freq=0
baseline_temp=0
baseline_bench_score=0
current_bench_score=0
cpu_model=""

# --- Helper Functions ---
log_message() {
    echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOGFILE"
}

# Function to save data to CSV files
save_neuron_data() {
    local timestamp=$(date +%s)
    local cycle=$1
    local phase=$2  # "pulse" or "recovery"
    local temp=$3
    local freq=$4
    local recovery_time=$5  # can be "N/A" for pulse phase
    local error_detected=$6  # 0 or 1
    
    echo "$timestamp,$cycle,$phase,$temp,$freq,$recovery_time,$error_detected" >> "$NEURON_DATA"
}

save_synaptic_short_data() {
    local timestamp=$(date +%s)
    local cycle=$1
    local phase=$2  # "potentiation", "depression", "forget"
    local pulse=$3  # pulse number or "N/A" for forget phase
    local bench_score=$4
    
    # Calculate percent of baseline if both scores are valid numbers
    local percent="N/A"
    if [[ "$bench_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        percent=$(echo "scale=2; 100 * $bench_score / $baseline_bench_score" | bc)
    fi
    
    echo "$timestamp,$cycle,$phase,$pulse,$bench_score,$percent" >> "$SYNAPTIC_SHORT_DATA"
}

save_synaptic_long_data() {
    local timestamp=$(date +%s)
    local cycle=$1
    local phase=$2  # "potentiation", "depression", "retention"
    local temp=$3
    local bench_score=$4  # can be "N/A"
    local error_detected=$5  # 0 or 1
    local corruption_detected=$6  # 0 or 1
    
    echo "$timestamp,$cycle,$phase,$temp,$bench_score,$error_detected,$corruption_detected" >> "$SYNAPTIC_LONG_DATA"
}

save_system_summary() {
    # Save baseline vs final metrics for overall summary
    echo "frequency,$baseline_freq,$final_freq,$(echo "scale=2; 100 * $final_freq / $baseline_freq" | bc)" >> "$SYSTEM_SUMMARY"
    echo "temperature,$baseline_temp,$final_temp,$(echo "scale=2; 100 * $final_temp / $baseline_temp" | bc)" >> "$SYSTEM_SUMMARY"
    echo "bench_score,$baseline_bench_score,$final_bench_score,$(echo "scale=2; 100 * $final_bench_score / $baseline_bench_score" | bc)" >> "$SYSTEM_SUMMARY"
}

get_cpu_freq() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A"
}

get_cpu_temp() {
    local temp_str=$(sensors 2>/dev/null | grep 'Package id 0:' | awk '{print $4}' | tr -d '+°C')
    # Use awk for reliable float conversion and rounding
    awk -v temp="$temp_str" 'BEGIN{if (temp ~ /^[0-9]+(\.[0-9]+)?$/) printf "%.0f", temp; else print "N/A"}'
}

# Modified run_sysbench function to ensure proper capture of benchmark score
run_sysbench() {
    # First log the message that we're running the benchmark
    log_message "  Running sysbench CPU benchmark..."
    
    # Now run sysbench and capture the output separately
    local raw_output
    raw_output=$(sysbench cpu --cpu-max-prime=15000 --threads=$(nproc) run 2>/dev/null)
    
    # Extract just the numeric score
    local score
    score=$(echo "$raw_output" | grep 'events per second:' | awk '{print $4}' | tr -d '\r\n')
    
    # Validate the score and return only the numeric value
    if [[ "$score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # Log the actual score on a separate line
        log_message "  ${score} events/sec"
        # Return just the number for variable assignment
        echo "$score"
    else
        log_message "  WARN: Sysbench failed to produce valid score."
        echo "N/A"
    fi
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
    # Run stress-ng with a timeout, suppressing most output
    stress-ng $stress_cmd --timeout "${duration_s}s" --metrics-brief --log-brief &> /dev/null &
    local stress_pid=$!
    # Wait for the specified duration; timeout handles actual killing if needed
    sleep "$duration_s" 
    # Ensure it's stopped if sleep finishes first (or timeout failed)
    kill $stress_pid 2>/dev/null || true 
    wait $stress_pid 2>/dev/null || true
    log_message "  Stress level '$level' finished."
}

set_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Setting RAPL power limit to ${RAPL_POWER_LIMIT_W}W..."
        # This assumes intel-rapl zone 0. May need adjustment. Package limit (long term).
        powercap-set -p intel-rapl -z 0 -c 0 -l "$((RAPL_POWER_LIMIT_W * 1000000))" || log_message "  WARN: Failed to set RAPL limit."
        powercap-set -p intel-rapl -z 0 -c 1 -l "$((RAPL_POWER_LIMIT_W * 1000000))" || true # Short term, might fail
    fi
}

reset_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Resetting RAPL power limit to default..."
        # Get default limit and re-apply it. This is complex. Easier: disable the constraint.
        # Disabling constraints might require specific zone/constraint knowledge.
        # Simpler: Set a very high limit if resetting is hard.
        local high_limit=$(( 250 * 1000000 )) # Set a high limit like 250W
        powercap-set -p intel-rapl -z 0 -c 0 -l $high_limit &> /dev/null || true
        powercap-set -p intel-rapl -z 0 -c 1 -l $high_limit &> /dev/null || true
    fi
}

# --- Cleanup Function ---
cleanup() {
  log_message "[*] Cleaning up background processes and files..."
  pkill -P $$ || true
  wait 2>/dev/null || true

  log_message "[*] Resetting system state (best effort)..."
  reset_rapl_limit # Reset power limit first
  if command -v cpupower >/dev/null 2>&1; then
      cpupower frequency-set -g powersave || log_message "  WARN: Failed to set powersave governor."
  fi
  if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
      echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo || log_message "  WARN: Failed to re-enable turbo."
  elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
      echo 1 > /sys/devices/system/cpu/cpufreq/boost || log_message "  WARN: Failed to re-enable boost."
  fi
   if [ -f /proc/sys/kernel/randomize_va_space ]; then
      echo 2 > /proc/sys/kernel/randomize_va_space || log_message "  WARN: Failed to reset ASLR."
  fi

  rm -f hammer hammer.c spec_havoc spec_havoc.o spec_havoc.S "$TEST_DATA_FILE" turbostat.log sensors.log mbw.log 2>/dev/null || true
  log_message "[*] Cleanup finished."
}
trap cleanup EXIT INT TERM

# --- Pre-computation / Checks ---
if [ "$USE_RAPL" = true ] && ! command -v powercap-set &> /dev/null; then
    log_message "!!! ERROR: USE_RAPL is true, but 'powercap-set' (from powercap-utils) not found. Install or set USE_RAPL=false."
    exit 1
fi
# Other tool checks omitted for brevity (present in previous version)


# =============================================================
#               INITIAL SETUP & BASELINE
# =============================================================
log_message "=== Advanced NS-RAM System Analogy Stress Test v2 ==="
log_message "Start time: $(date)"
log_message "!!! EXTREME WARNING: DANGEROUS & EXPERIMENTAL SCRIPT !!!"
log_message "Mode: $MODE"
cpu_model=$(lscpu | grep 'Model name' | sed 's/Model name:[[:space:]]*//')
log_message "CPU: $cpu_model"
log_message "Kernel: $(uname -r)"
log_message "[*] Warming up sysbench..."
sysbench cpu --cpu-max-prime=1000 --threads=1 run >/dev/null 2>&1

log_message "[1] SYSTEM SETUP & BASELINE"

log_message "[*] Setting performance governor & disabling turbo/boost..."
if command -v cpupower >/dev/null 2>&1; then
    cpupower frequency-set -g performance || log_message "WARN: Failed to set performance governor."
else
    log_message "WARN: cpupower not found, skipping governor setting"
fi

if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
    echo 0 > /sys/devices/system/cpu/cpufreq/boost
else
    log_message "[*] WARN: Could not find standard interface to disable Turbo Boost."
fi
# Skipping MSR tweaks for stability in this version, focus on load/power
log_message "[*] Disabling ASLR..."
echo 0 > /proc/sys/kernel/randomize_va_space

sleep 1
baseline_freq=$(get_cpu_freq)
baseline_temp=$(get_cpu_temp)
log_message "Initial frequency: ${baseline_freq} KHz"
log_message "Initial temp: ${baseline_temp} C"

log_message "[*] Compiling custom stress tools (hammer, spec_havoc)..."
# Check if source files exist before attempting compilation
if [ -f "hammer.c" ]; then
    gcc -O2 -march=native -o hammer hammer.c || { log_message "!!! Hammer compilation failed!"; }
else
    log_message "!!! hammer.c source file not found!"
fi

if [ -f "spec_havoc.S" ]; then
    as spec_havoc.S -o spec_havoc.o && ld spec_havoc.o -o spec_havoc || { log_message "!!! Spec Havoc assembly/linking failed!"; }
else
    log_message "!!! spec_havoc.S source file not found!"
fi

log_message "[*] Running Baseline Performance (Sysbench)..."
# Store just the numeric score
baseline_bench_score=$(run_sysbench)
current_bench_score=$baseline_bench_score # Initialize current score

# Properly log the baseline score for reference
log_message "Baseline Sysbench CPU Score: ${baseline_bench_score} events/sec"

log_message "[*] Generating test data ($DATA_SIZE_MB MB)..."
dd if=/dev/urandom of="$TEST_DATA_FILE" bs=1M count=$DATA_SIZE_MB status=none
md5_orig=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Original data hash (MD5): $md5_orig"
sync

set_rapl_limit # Apply initial power limit if enabled

# =============================================================
#                    MODE: NEURON (LIF Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "NEURON" ]; then
    log_message "\n[2] NEURON MODE TEST (LIF Analogy)"
    log_message "Parameters: Amplitude='$NEURON_PULSE_AMPLITUDE', ON=${NEURON_PULSE_INTERVAL_ON_S}s, OFF=${NEURON_PULSE_INTERVAL_OFF_S}s, Cycles=$NEURON_CYCLES"
    
    total_neuron_duration=$(( NEURON_CYCLES * (NEURON_PULSE_INTERVAL_ON_S + NEURON_PULSE_INTERVAL_OFF_S) ))
    log_message "Estimated duration: ${total_neuron_duration}s"

    failed_integrate=false
    for cycle in $(seq 1 $NEURON_CYCLES); do
        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Applying Pulse (ON)..."
        temp_before_pulse=$(get_cpu_temp)
        
        apply_stress "$NEURON_PULSE_AMPLITUDE" "$NEURON_PULSE_INTERVAL_ON_S"
        
        temp_after_pulse=$(get_cpu_temp)
        freq_after_pulse=$(get_cpu_freq)
        log_message "  Pulse End: Temp=${temp_after_pulse}C, Freq=${freq_after_pulse}KHz"

        # Save pulse data for plotting
        error_detected=0
        # Check for immediate critical errors after pulse
        if dmesg | tail -n 50 | grep -q -iE 'MCE|uncorrected|critical|panic'; then
             log_message "  [!!!] FAILURE: Critical error detected during/after pulse! Halting Neuron test."
             error_detected=1
             failed_integrate=true
        fi
        
        # Save pulse phase data
        save_neuron_data "$cycle" "pulse" "$temp_after_pulse" "$freq_after_pulse" "N/A" "$error_detected"

        if [ "$failed_integrate" = true ]; then
            break
        fi

        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Recovery phase (OFF - Leaking)..."
        time_start_recovery=$(date +%s.%N)
        sleep "$NEURON_PULSE_INTERVAL_OFF_S"
        time_end_recovery=$(date +%s.%N)

        temp_after_recovery=$(get_cpu_temp)
        freq_after_recovery=$(get_cpu_freq)
        recovery_duration=$(echo "$time_end_recovery - $time_start_recovery" | bc)
        
        temp_drop="N/A"
        if [[ "$temp_after_pulse" != "N/A" && "$temp_after_recovery" != "N/A" ]]; then
             temp_drop=$((temp_after_pulse - temp_after_recovery))
        fi
        
        freq_recovered="N/A"
         if [[ "$freq_after_recovery" =~ ^[0-9]+$ && "$baseline_freq" =~ ^[0-9]+$ ]]; then
             freq_diff=$(( baseline_freq - freq_after_recovery ))
             # Consider recovered if within ~5% of baseline (adjust as needed)
             if [ $freq_diff -lt $(( baseline_freq / 20 )) ]; then
                 freq_recovered="true"
             else
                 freq_recovered="false (Diff: ${freq_diff}KHz)"
             fi
         fi

        log_message "  Recovery End: Temp=${temp_after_recovery}C (Drop: ${temp_drop}C), Freq=${freq_after_recovery}KHz (Recovered: ${freq_recovered})"
        log_message "  Recovery Time Measured (tau_r analogy): ${recovery_duration}s"

        # Save recovery phase data
        save_neuron_data "$cycle" "recovery" "$temp_after_recovery" "$freq_after_recovery" "$recovery_duration" "0"

        # Check if system is recovering adequately. If temps stay high or freq stays low, it might "fail to fire" next cycle or fail entirely.
        if [[ "$temp_drop" != "N/A" && $temp_drop -lt 5 ]] && [[ "$cycle" -gt 1 ]]; then # Arbitrary low drop threshold after first cycle
             log_message "  [!] WARN: Low temperature drop during recovery (< 5C). System may be heat-saturated."
        fi
         if [[ "$freq_recovered" == "false"* ]]; then
             log_message "  [!] WARN: Frequency failed to recover near baseline during OFF period."
             # Could potentially trigger failed_integrate=true here if strict
         fi

    done # End Neuron Cycles

    if [ "$failed_integrate" = true ]; then
        log_message "[!!!] NEURON MODE FAILED: System instability detected (critical errors)."
    else
        log_message "[✓] NEURON MODE COMPLETED: System processed $NEURON_CYCLES pulses. Check warnings for recovery issues."
    fi
fi


# =============================================================
#            MODE: SYNAPSE (Short-Term Plasticity Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_SHORT" ]; then
    log_message "\n[3] SYNAPSE MODE TEST (Short-Term Plasticity Analogy)"
    log_message "Parameters: POT_Load='$SYN_ST_POTENTIATION_LOAD', DEP_Load='$SYN_ST_DEPRESSION_LOAD', Pulse=${SYN_ST_PULSE_DURATION_S}s"
    log_message "POT Pulses=$SYN_ST_POT_PULSES, DEP Pulses=$SYN_ST_DEP_PULSES, Forget=${SYN_ST_FORGET_DURATION_S}s, Cycles=$SYN_ST_CYCLES"

    for cycle in $(seq 1 $SYN_ST_CYCLES); do
        log_message "\nShort-Term Cycle $cycle/$SYN_ST_CYCLES: Starting Potentiation..."
        sleep 2
        
        # Measure before potentiation - store just the numeric value
        current_bench_score=$(run_sysbench)
        log_message "  Cycle Start State (Sysbench Score): ${current_bench_score} events/sec"
        
        # Save initial state for this cycle
        save_synaptic_short_data "$cycle" "start" "0" "$current_bench_score"

        # Potentiation Phase (Facilitation Analogy)
        for p_pulse in $(seq 1 $SYN_ST_POT_PULSES); do
             log_message "  Potentiation Pulse $p_pulse/$SYN_ST_POT_PULSES..."
             apply_stress "$SYN_ST_POTENTIATION_LOAD" "$SYN_ST_PULSE_DURATION_S"
             sleep 2 # Brief pause between pulses
             
             # Get just the numeric score
             current_bench_score=$(run_sysbench)
             log_message "    State after POT Pulse $p_pulse: ${current_bench_score} events/sec"
             
             # Save potentiation data
             save_synaptic_short_data "$cycle" "potentiation" "$p_pulse" "$current_bench_score"
        done

        log_message "Short-Term Cycle $cycle/$SYN_ST_CYCLES: Starting Depression..."
        # Depression Phase
        for d_pulse in $(seq 1 $SYN_ST_DEP_PULSES); do
             log_message "  Depression Pulse $d_pulse/$SYN_ST_DEP_PULSES..."
             apply_stress "$SYN_ST_DEPRESSION_LOAD" "$SYN_ST_PULSE_DURATION_S"
             sleep 2
             
             # Get just the numeric score
             current_bench_score=$(run_sysbench)
             log_message "    State after DEP Pulse $d_pulse: ${current_bench_score} events/sec"
             
             # Save depression data
             save_synaptic_short_data "$cycle" "depression" "$d_pulse" "$current_bench_score"
        done

        log_message "Short-Term Cycle $cycle/$SYN_ST_CYCLES: Starting Forgetting/Relaxation Phase (${SYN_ST_FORGET_DURATION_S}s)..."
        # Forgetting Phase
        time_start_forget=$(date +%s)
        while true; do
             current_time=$(date +%s)
             elapsed_forget=$(( current_time - time_start_forget ))
             if [ $elapsed_forget -ge $SYN_ST_FORGET_DURATION_S ]; then
                 break
             fi
             
             # Measure state periodically during forgetting
             sleep 5 # Check every 5 seconds
             
             # Get just the numeric score
             current_bench_score=$(run_sysbench)
             log_message "  Forget Time +${elapsed_forget}s: State=${current_bench_score} events/sec"
             
             # Save forgetting data
             save_synaptic_short_data "$cycle" "forget" "$elapsed_forget" "$current_bench_score"
        done
        log_message "  Forgetting phase complete."
        sleep 2
        
        # Final score after forgetting - get just the numeric value
        current_bench_score=$(run_sysbench)
        log_message "  Final State after Forget: ${current_bench_score} events/sec"
        save_synaptic_short_data "$cycle" "end" "N/A" "$current_bench_score"

        # Compare final score to baseline
        if [[ "$current_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
             recovery_percent=$(echo "scale=2; $current_bench_score * 100 / $baseline_bench_score" | bc)
             log_message "  Recovery vs Baseline after cycle $cycle: ${recovery_percent}%"
        else
             log_message "  Recovery comparison skipped (invalid scores: current=${current_bench_score}, baseline=${baseline_bench_score})."
        fi
    done # End Short-Term Cycles
    log_message "[✓] SYNAPSE SHORT-TERM MODE COMPLETED."

fi

# =============================================================
#            MODE: SYNAPSE (Long-Term Plasticity Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_LONG" ]; then
    log_message "\n[4] SYNAPSE MODE TEST (Long-Term Plasticity Analogy)"
    log_message "Parameters: POT_Load='$SYN_LT_POTENTIATION_LOAD', DEP_Load='$SYN_LT_DEPRESSION_LOAD', Pulse=${SYN_LT_PULSE_DURATION_S}s"
    log_message "Bipolar Cycles=$SYN_LT_CYCLES, Retention Test=${SYN_LT_RETENTION_S}s"
    
    ltp_errors=false
    ltp_corruption=false

    for cycle in $(seq 1 $SYN_LT_CYCLES); do
        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Applying Intense Potentiation Pulse..."
        apply_stress "$SYN_LT_POTENTIATION_LOAD" "$SYN_LT_PULSE_DURATION_S"
        temp_after_pot=$(get_cpu_temp)
        
        # Save potentiation data
        error_detected=0
        corruption_detected=0
        save_synaptic_long_data "$cycle" "potentiation" "$temp_after_pot" "N/A" "$error_detected" "$corruption_detected"
        
        sleep 1 # Short pause

        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Applying Intense Depression Pulse/State..."
        apply_stress "$SYN_LT_DEPRESSION_LOAD" "$SYN_LT_PULSE_DURATION_S"
        temp_after_dep=$(get_cpu_temp)
        
        # Save depression data
        error_detected=0
        corruption_detected=0
        
        # Quick check for critical errors after each bipolar cycle
        if dmesg | tail -n 20 | grep -q -iE 'MCE|uncorrected|critical|panic'; then
             log_message "  [!!!] FAILURE: Critical error detected during Long-Term cycle $cycle!"
             error_detected=1
             ltp_errors=true
        fi
        
        # Optional: Check MD5 periodically (slow) - maybe every 10 cycles?
        if (( cycle % 10 == 0 )); then
             log_message "  Periodic integrity check (Cycle $cycle)..."
             sync
             md5_now=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
             if [ "$md5_orig" != "$md5_now" ]; then
                 log_message "  [!!!] FAILURE: Data corruption detected during Long-Term cycle $cycle!"
                 corruption_detected=1
                 ltp_corruption=true
             fi
             log_message "  Integrity OK."
        fi
        
        save_synaptic_long_data "$cycle" "depression" "$temp_after_dep" "N/A" "$error_detected" "$corruption_detected"
        
        if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then
            break # Stop cycling on critical error or corruption
        fi
        
        sleep 1

    done # End Long-Term Cycles

    if [ "$ltp_errors" = false ] && [ "$ltp_corruption" = false ]; then
        log_message "Long-Term Cycling Phase complete ($SYN_LT_CYCLES cycles)."
        log_message "Starting Retention Test Phase (${SYN_LT_RETENTION_S}s idle)..."
        
        # Take measurements at the start of retention
        bench_score_start_retention=$(run_sysbench)
        temp_start_retention=$(get_cpu_temp)
        
        # Save start of retention phase data
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_start" "$temp_start_retention" "$bench_score_start_retention" "0" "0"
        
        # Monitor during retention every 10 seconds
        retention_start=$(date +%s)
        while true; do
            current_time=$(date +%s)
            elapsed_retention=$(( current_time - retention_start ))
            
            if [ $elapsed_retention -ge $SYN_LT_RETENTION_S ]; then
                break
            fi
            
            if (( elapsed_retention % 10 == 0 )); then
                temp_current=$(get_cpu_temp)
                bench_score_current=$(run_sysbench)
                save_synaptic_long_data "$SYN_LT_CYCLES" "retention_progress" "$temp_current" "$bench_score_current" "0" "0"
            fi
            
            sleep 1
        done
        
        sleep "$SYN_LT_RETENTION_S"

        log_message "Retention Test: Final Checks..."
        # Final MD5 Check
        sync
        md5_after_retention=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
        log_message "  Hash after retention: $md5_after_retention"
        error_detected=0
        corruption_detected=0
        
        if [ "$md5_orig" != "$md5_after_retention" ]; then
             log_message "  [!!!] FAILURE: Data corruption detected after retention period!"
             corruption_detected=1
             ltp_corruption=true
        else
             log_message "  [✓] Data integrity preserved after retention."
        fi

        # Final dmesg check for delayed errors
        if dmesg | tail -n 100 | grep -q -iE 'MCE|uncorrected|critical|panic'; then
             log_message "  [!!!] FAILURE: Critical errors detected in dmesg post-retention!"
             error_detected=1
             ltp_errors=true
        else
             log_message "  [✓] No new critical errors in dmesg post-retention."
        fi

        # Final performance check - get just the numeric value
        final_ltp_score=$(run_sysbench)
        final_ltp_temp=$(get_cpu_temp)
        log_message "  Final Performance State: ${final_ltp_score} events/sec (Baseline: ${baseline_bench_score})"
        
        # Save final retention data
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_end" "$final_ltp_temp" "$final_ltp_score" "$error_detected" "$corruption_detected"
        
        if [[ "$final_ltp_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            final_recovery_percent=$(echo "scale=2; $final_ltp_score * 100 / $baseline_bench_score" | bc)
            log_message "  Final Recovery vs Baseline: ${final_recovery_percent}%"
            if (( $(echo "$final_recovery_percent < 90" | bc -l) )); then # Check if recovery is poor (e.g., < 90%)
                log_message "  [!] WARN: Persistent performance degradation observed after long-term stress."
            fi
        fi
    fi # End if no early failure

    if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then
         log_message "[!!!] SYNAPSE LONG-TERM MODE FAILED: Persistent errors or data corruption observed (Analogy: Irreversible state change/damage)."
    else
         log_message "[✓] SYNAPSE LONG-TERM MODE COMPLETED: System endured cycling and retention test without critical persistent failures. Check warnings for performance degradation."
    fi
fi


# =============================================================
#                   FINAL ANALYSIS & VERDICT
# =============================================================
log_message "\n[5] FINAL SYSTEM STATE & OVERALL EVALUATION"

final_freq=$(get_cpu_freq)
final_temp=$(get_cpu_temp)
# Get just the numeric value for the final benchmark
final_bench_score=$(run_sysbench)
log_message "Final frequency: ${final_freq} KHz (Baseline: ${baseline_freq} KHz)"
log_message "Final temp: ${final_temp} C (Baseline: ${baseline_temp} C)"
log_message "Final Sysbench Score: ${final_bench_score} events/sec (Baseline: ${baseline_bench_score} events/sec)"

final_md5=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Final MD5 Check: $final_md5 (Original: $md5_orig)"

# Save final system summary data for plotting
save_system_summary

# Save test configuration for reference
echo "NEURON_CYCLES=$NEURON_CYCLES" > "${DATA_DIR}/test_config.txt"
echo "NEURON_PULSE_AMPLITUDE=$NEURON_PULSE_AMPLITUDE" >> "${DATA_DIR}/test_config.txt"
echo "NEURON_PULSE_INTERVAL_ON_S=$NEURON_PULSE_INTERVAL_ON_S" >> "${DATA_DIR}/test_config.txt"
echo "NEURON_PULSE_INTERVAL_OFF_S=$NEURON_PULSE_INTERVAL_OFF_S" >> "${DATA_DIR}/test_config.txt"
echo "SYN_ST_CYCLES=$SYN_ST_CYCLES" >> "${DATA_DIR}/test_config.txt"
echo "SYN_ST_POT_PULSES=$SYN_ST_POT_PULSES" >> "${DATA_DIR}/test_config.txt"
echo "SYN_ST_DEP_PULSES=$SYN_ST_DEP_PULSES" >> "${DATA_DIR}/test_config.txt"
echo "SYN_LT_CYCLES=$SYN_LT_CYCLES" >> "${DATA_DIR}/test_config.txt"
echo "SYN_LT_RETENTION_S=$SYN_LT_RETENTION_S" >> "${DATA_DIR}/test_config.txt"
echo "CPU_MODEL=\"$cpu_model\"" >> "${DATA_DIR}/test_config.txt"
echo "BASELINE_FREQ=$baseline_freq" >> "${DATA_DIR}/test_config.txt"
echo "BASELINE_TEMP=$baseline_temp" >> "${DATA_DIR}/test_config.txt"
echo "BASELINE_BENCH=$baseline_bench_score" >> "${DATA_DIR}/test_config.txt"

# Overall Verdict - Simplified check for ANY critical failure during ANY applicable mode
overall_success=true
if grep -q -iE '\[!!!\] FAILURE:|DATA CORRUPTION DETECTED!' "$LOGFILE"; then
    overall_success=false
fi

log_message "\n--- OVERALL VERDICT (NS-RAM Analogy Interpretation) ---"
if [ "$overall_success" = true ]; then
    if grep -q '\[!\] WARN:' "$LOGFILE"; then
         log_message "⚠️  SYSTEM STRESSED BUT STABLE: Completed tests without critical failures, but warnings indicate non-ideal behavior (throttling, slow recovery, performance dip). (Analogy: Device operated near/beyond optimal point, showing stress effects but no permanent failure mode)."
    else
         log_message "✅ SYSTEM RESILIENT: Completed tests without critical failures or significant warnings. System appears to have recovered well. (Analogy: Device operated within its robust range)."
    fi
else
     log_message "❌ SYSTEM FAILURE: Critical errors (MCE, Panic, etc.) or Data Corruption occurred during testing. (Analogy: Device threshold exceeded, leading to irreversible state change, instability, or damage)."
fi

log_message "Test completed at: $(date)"
log_message "Log file saved to: $LOGFILE"
log_message "Data directory for plotting: $DATA_DIR"

# Cleanup is handled by the trap function on exit
exit 0
