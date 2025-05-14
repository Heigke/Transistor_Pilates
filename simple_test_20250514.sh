#!/bin/bash

# ─────────────────────────────────────────────────────────────
# Simplified System-Level Analogy Stress Test (Neuron LIF Focus) v0.1
# Based on concepts from Advanced NS-RAM System-Level Analogy Stress Suite v2.3
# Maps transistor dynamics to system behaviors:
# - Neuron mode: Leaky Integrate & Fire (LIF)
#   - Integrate: System heats up under load.
#   - Fire: System reaches peak temperature / throttles frequency.
#   - Leak: System cools down, frequency recovers post-load.
# !!! FOR TEST MACHINES !!!
# ─────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Please run as root or with sudo." >&2
    exit 1
fi

set -euo pipefail

# --- Configuration ---
STRESS_DURATION_S=60       # How long to apply the main stress
RECOVERY_DURATION_S=120    # How long to monitor after stress
MONITOR_INTERVAL_S=1       # How often to take measurements
CPU_STRESS_LOAD_THREADS=$(nproc) # Number of CPU stress threads
# Use $(($(nproc)/2)) or a fixed number like 1 or 2 for less intense stress

RUN_ID=$(date +%Y%m%d_%H%M%S)
DATA_DIR="simplified_stress_data_${RUN_ID}"
mkdir -p "$DATA_DIR"
LOGFILE="${DATA_DIR}/stress_analog_run.log"
NEURON_DATA_CSV="${DATA_DIR}/neuron_lif_analogy_data.csv"

# --- Tool Functions ---
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOGFILE" >&2
}

# Package manager detection and installation
install_packages() {
    local missing_pkgs=()
    # Reduced list of essential packages
    local essential_packages=(stress-ng lm-sensors coreutils bc) # sysbench for optional baseline

    for pkg in "${essential_packages[@]}"; do
        if ! command -v "${pkg%%-*}" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null; then
            # Attempt to handle cases like lm-sensors (command is sensors)
            local cmd_check="${pkg%%-*}"
            if [ "$pkg" == "lm-sensors" ]; then cmd_check="sensors"; fi
             if ! command -v "$cmd_check" &>/dev/null; then
                missing_pkgs+=("$pkg")
            fi
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_message "[+] Installing missing packages: ${missing_pkgs[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq || log_message "[WARN] apt-get update failed."
            apt-get install -y -qq "${missing_pkgs[@]}" || log_message "[WARN] Failed to install some packages: ${missing_pkgs[*]}. Some features might not work."
        else
            log_message "[ERROR] Unsupported package manager. Please manually install: ${missing_pkgs[*]}"
            exit 1
        fi
    fi

    if command -v sensors-detect &>/dev/null && command -v sensors &>/dev/null; then
        # Only run sensors-detect if sensors seems configured but not finding anything obvious
        if ! sensors | grep -qE 'Adapter|Core|temp'; then
            log_message "[*] Running sensors-detect (auto-confirm) as initial sensor data seems sparse..."
            yes | sensors-detect >/dev/null 2>&1 || log_message "[WARN] sensors-detect run had issues."
        fi
    elif command -v apt-get &>/dev/null && ! command -v sensors &>/dev/null; then
         log_message "[WARN] lm-sensors/sensors command not found. Temperature readings might not be available. Attempting install."
         apt-get install -y -qq lm-sensors || log_message "[WARN] Failed to install lm-sensors."
    elif ! command -v sensors &>/dev/null; then
        log_message "[WARN] sensors command not found. Temperature readings might not be available."
    fi
}


get_cpu_freq_khz() {
    # Try lscpu first, then /sys/devices, then specific scaling_cur_freq
    local freq_mhz
    freq_mhz=$(lscpu -p=CPU,MHZ | grep -E '^[0-9]+,' | head -n1 | awk -F, '{print $2}' 2>/dev/null)
    if [[ "$freq_mhz" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf "%.0f000" "$freq_mhz"
        return
    fi

    if [ -r /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq ]; then
        cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || echo "N/A"
    elif [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

get_cpu_temp_c() {
    local temp_val="N/A"
    if command -v sensors &>/dev/null; then
        # Prioritize Package or Core 0 temp, then any Tdie, then any temp1/input from common CPU/motherboard sensors
        temp_val=$(sensors 2>/dev/null | grep -iE 'Package id 0:|Core 0:|Tdie:|temp1:.*\(CRIT|temp1_input:' | head -n1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^\+[0-9]+(\.[0-9]+)?°C$/) {sub(/^\+/,"",$i); sub(/°C$/,"",$i); print $i; exit}}')
    fi
    # Fallback if no specific pattern found, take first generic temp
    if [[ -z "$temp_val" || "$temp_val" == "N/A" ]] && command -v sensors &>/dev/null; then
         temp_val=$(sensors 2>/dev/null | awk '/\+[0-9]+\.[0-9]+°C/ {gsub(/^\+/,""); gsub(/°C$/,""); print $0; exit}' | awk '{print $1}')
    fi
    [ -z "$temp_val" ] || [[ ! "$temp_val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && temp_val="N/A"
    echo "$temp_val"
}

apply_cpu_stress() {
    local duration_s=$1
    local num_threads=$2
    if [ "$duration_s" -le 0 ]; then return; fi
    log_message "  Applying CPU stress: $num_threads threads for ${duration_s}s..."
    # Basic CPU stress. Add --vm 1 --vm-bytes 256M for some memory pressure if desired.
    stress-ng --cpu "$num_threads" --cpu-load 100 --timeout "${duration_s}s" --metrics-brief --log-brief &>/dev/null &
    local stress_pid=$!
    wait "$stress_pid" 2>/dev/null || true # Wait for it to finish or be killed
    log_message "  CPU stress finished."
}

_CLEANUP_RUNNING=0
cleanup() {
  if [ "$_CLEANUP_RUNNING" -ne 0 ]; then return; fi; _CLEANUP_RUNNING=1
  log_message "[*] Cleaning up potential stray processes..."
  # Kill any stress-ng processes that might be lingering
  pkill -f stress-ng 2>/dev/null || true
  if [ -n "${stress_pid:-}" ] && ps -p "$stress_pid" > /dev/null; then
      kill "$stress_pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$stress_pid" 2>/dev/null || true
  fi
  log_message "[*] Cleanup finished."
  _CLEANUP_RUNNING=0
}
trap cleanup EXIT INT TERM

# --- Main ---
install_packages
log_message "=== Simplified System-Level Analogy Stress Test (Neuron LIF Focus) v0.1 ==="
log_message "Start time: $(date)"
log_message "Logging to: $LOGFILE"
log_message "Data CSV: $NEURON_DATA_CSV"
log_message "CPU: $(lscpu | grep 'Model name' | sed 's/Model name:[[:space:]]*//' || echo "Unknown CPU")"
log_message "Kernel: $(uname -r)"

echo "timestamp_utc,timestamp_epoch_s,phase,temp_c,freq_khz" > "$NEURON_DATA_CSV"

# Phase: Baseline (very short)
log_message "[1] Capturing Initial Baseline State..."
current_temp_c=$(get_cpu_temp_c)
current_freq_khz=$(get_cpu_freq_khz)
log_message "  Initial: Temp=${current_temp_c}C, Freq=${current_freq_khz}KHz"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),baseline,${current_temp_c},${current_freq_khz}" >> "$NEURON_DATA_CSV"
sleep $MONITOR_INTERVAL_S

# Phase: Integrate & Fire (Stress Application)
log_message "[2] Starting 'Integrate & Fire' Analogy (CPU Stress for ${STRESS_DURATION_S}s)..."
stress_start_time=$(date +%s)
# Run stress in background so we can monitor
(apply_cpu_stress "$STRESS_DURATION_S" "$CPU_STRESS_LOAD_THREADS") &
stress_bg_pid=$!

current_loop_time=0
while [ "$current_loop_time" -lt "$STRESS_DURATION_S" ]; do
    current_temp_c=$(get_cpu_temp_c)
    current_freq_khz=$(get_cpu_freq_khz)
    log_message "  Stressing ($((current_loop_time+MONITOR_INTERVAL_S))s/${STRESS_DURATION_S}s): Temp=${current_temp_c}C, Freq=${current_freq_khz}KHz"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),stress,${current_temp_c},${current_freq_khz}" >> "$NEURON_DATA_CSV"
    
    sleep $MONITOR_INTERVAL_S
    current_loop_time=$((current_loop_time + MONITOR_INTERVAL_S))
    # Check if stress_bg_pid ended early
    if ! ps -p "$stress_bg_pid" > /dev/null; then
        log_message "  Stress process $stress_bg_pid ended earlier than expected."
        break
    fi
done
wait "$stress_bg_pid" 2>/dev/null || true # Ensure it's finished
log_message "'Integrate & Fire' phase complete."

# Phase: Leak & Recover
log_message "[3] Starting 'Leak & Recover' Analogy (Monitoring for ${RECOVERY_DURATION_S}s)..."
current_loop_time=0
while [ "$current_loop_time" -lt "$RECOVERY_DURATION_S" ]; do
    current_temp_c=$(get_cpu_temp_c)
    current_freq_khz=$(get_cpu_freq_khz)
    log_message "  Recovering ($((current_loop_time+MONITOR_INTERVAL_S))s/${RECOVERY_DURATION_S}s): Temp=${current_temp_c}C, Freq=${current_freq_khz}KHz"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ"),$(date +%s),recovery,${current_temp_c},${current_freq_khz}" >> "$NEURON_DATA_CSV"
    sleep $MONITOR_INTERVAL_S
    current_loop_time=$((current_loop_time + MONITOR_INTERVAL_S))
done
log_message "'Leak & Recover' phase complete."

log_message "[4] Test Finished."
log_message "Review data in: $NEURON_DATA_CSV"
log_message "Full log in: $LOGFILE"

# Optional: Basic plot generation if python3-matplotlib is available
if command -v python3 &>/dev/null && python3 -c "import matplotlib; import pandas" &>/dev/null; then
    log_message "Attempting to generate a simple plot..."
    python3 << EOF
import pandas as pd
import matplotlib.pyplot as plt
import os

csv_file = "$NEURON_DATA_CSV"
output_plot_file = "${DATA_DIR}/temp_freq_plot.png"

if not os.path.exists(csv_file) or os.path.getsize(csv_file) == 0:
    print(f"CSV file {csv_file} is empty or does not exist. Skipping plot.")
else:
    try:
        df = pd.read_csv(csv_file)
        df['timestamp_epoch_s'] = pd.to_numeric(df['timestamp_epoch_s'], errors='coerce')
        df['temp_c'] = pd.to_numeric(df['temp_c'], errors='coerce')
        df['freq_khz'] = pd.to_numeric(df['freq_khz'], errors='coerce')
        df.dropna(subset=['timestamp_epoch_s', 'temp_c', 'freq_khz'], inplace=True)

        if not df.empty:
            fig, ax1 = plt.subplots(figsize=(12, 6))

            color = 'tab:red'
            ax1.set_xlabel('Time (s from start)')
            ax1.set_ylabel('Temperature (°C)', color=color)
            ax1.plot(df['timestamp_epoch_s'] - df['timestamp_epoch_s'].iloc[0], df['temp_c'], color=color, marker='o', linestyle='-')
            ax1.tick_params(axis='y', labelcolor=color)
            # Add phase lines
            last_phase = None
            for i, row in df.iterrows():
                if row['phase'] != last_phase and last_phase is not None:
                     ax1.axvline(x=row['timestamp_epoch_s'] - df['timestamp_epoch_s'].iloc[0], color='gray', linestyle='--', alpha=0.7, label=f'{last_phase} end' if i==0 else None) # Label only once
                last_phase = row['phase']


            ax2 = ax1.twinx()  # instantiate a second axes that shares the same x-axis
            color = 'tab:blue'
            ax2.set_ylabel('Frequency (KHz)', color=color)
            ax2.plot(df['timestamp_epoch_s'] - df['timestamp_epoch_s'].iloc[0], df['freq_khz'], color=color, marker='x', linestyle='--')
            ax2.tick_params(axis='y', labelcolor=color)

            fig.tight_layout()  # otherwise the right y-label is slightly clipped
            plt.title('System Temperature and Frequency Over Time (LIF Analogy)')
            # Create a single legend for phases if possible, or just use vlines as indicators
            # Handles for legend
            handles, labels = [], []
            if any(df['phase']=='stress'): handles.append(plt.Line2D([0], [0], color='gray', linestyle='--', label='Phase Change'))
            if not handles: # if no phase changes, legend is empty
                 fig.legend(loc="upper right")
            else:
                 fig.legend(handles, labels, loc="upper right", bbox_to_anchor=(1,1), bbox_transform=ax1.transAxes)


            plt.savefig(output_plot_file)
            print(f"Plot saved to {output_plot_file}")
        else:
            print(f"No valid data to plot in {csv_file}")

    except Exception as e:
        print(f"Failed to generate plot: {e}")
EOF
else
    log_message "Python3 with Matplotlib and Pandas not found. Skipping plot generation."
    log_message "You can plot '$NEURON_DATA_CSV' manually using your preferred tool."
fi
sudo chown -R blue:blue .
exit 0