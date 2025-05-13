#!/bin/bash

# ─────────────────────────────────────────────────────────────
# Advanced NS-RAM System-Level Analogy Stress Suite v2.1
# !!! EXTREME DANGER - CONCEPTUAL ANALOGY ONLY - FOR TEST MACHINES !!!
# 
# Maps NS-RAM transistor dynamics to system behaviors:
# - Neuron mode: Leaky Integrate & Fire (LIF)
# - Synapse modes: Short & Long-Term Plasticity (STP/LTP)
# 
# Enhanced to better match Nature publication (Vol 640, pp. 69-76)
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
    linux-tools-common
    "linux-tools-$(uname -r)"
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
)

# Package manager detection and installation
if command -v apt-get &>/dev/null; then
    apt-get update
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            log_install "$pkg"
            apt-get install -y "$pkg" || echo "Failed to install $pkg, continuing..."
        fi
    done
    # Try installing cpupower separately
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

# --- Configuration ---
MODE="ALL"               # Options: "ALL", "NEURON", "SYNAPSE_SHORT", "SYNAPSE_LONG"
TOTAL_DURATION_S=120     # Maximum duration for test modes
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

# --- NS-RAM Analog Parameters ---
# ** Neuron Mode Parameters (LIF model analogy) **
NEURON_PULSE_AMPLITUDE="max"     # Stress level during pulse: "max", "high", "medium"
NEURON_PULSE_INTERVAL_ON_S=5     # Duration of stress pulse (τon) 
NEURON_PULSE_INTERVAL_OFF_S=5    # Duration of recovery/leak period (τoff/τleak)
NEURON_CYCLES=10                 # Number of pulses to apply (pulse train)

# ** Synapse Short-Term Plasticity Parameters **
SYN_ST_POTENTIATION_LOAD="high"  # Stress level for potentiation phase
SYN_ST_DEPRESSION_LOAD="idle"    # Stress level for depression phase
SYN_ST_PULSE_DURATION_S=3        # Duration of each potentiation/depression pulse
SYN_ST_POT_PULSES=5              # Number of potentiation pulses in sequence
SYN_ST_DEP_PULSES=5              # Number of depression pulses in sequence
SYN_ST_FORGET_DURATION_S=30      # Duration to monitor relaxation/forgetting
SYN_ST_CYCLES=3                  # Number of full P->D->F cycles

# ** Synapse Long-Term Plasticity Parameters **
SYN_LT_POTENTIATION_LOAD="max"   # Stress for potentiation (charge trapping analog)
SYN_LT_DEPRESSION_LOAD="idle"    # Depression phase load
SYN_LT_PULSE_DURATION_S=10       # Longer pulses for potential charge trapping
SYN_LT_CYCLES=50                 # Number of bipolar stress cycles
SYN_LT_RETENTION_S=60            # Time to check for persistent effects

# ** Power Limiting (RAPL - Analogy for voltage/current limiting) **
USE_RAPL=false                   # Enable power capping
RAPL_POWER_LIMIT_W=50            # Power limit in Watts (adjust based on CPU TDP)

# ** Memory Hammer Parameters (Row hammer analog) **
HAMMER_ITERATIONS=5000000        # Iterations for hammer test
HAMMER_PATTERN_LENGTH=4          # Number of addresses in hammer pattern
HAMMER_WRITE_OPS=1               # Enable write operations (more aggressive)
HAMMER_THREAD_COUNT=2            # Parallel hammering threads

# --- Stress Level Definitions ---
declare -A STRESS_PARAMS
STRESS_PARAMS["max"]="--cpu $(nproc) --matrix $(nproc) --vm $(nproc) --vm-bytes 1G --cpu-method all"
STRESS_PARAMS["high"]="--cpu $(nproc) --matrix 0 --vm $(nproc) --vm-bytes 512M --cpu-method int64,float"
STRESS_PARAMS["medium"]="--cpu $(($(nproc)/2)) --matrix 0 --vm 0 --cpu-method bitops"
STRESS_PARAMS["low"]="--cpu 1 --vm 0 --cpu-method trivial"
STRESS_PARAMS["idle"]="" # No explicit stress-ng load

# --- Global Variables ---
baseline_freq=0
baseline_temp=0
baseline_bench_score=0
current_bench_score=0
cpu_model=""
final_freq=0
final_temp=0
final_bench_score=0

# --- Helper Functions ---
log_message() {
    echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOGFILE"
}

# Data saving functions
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
    # Save baseline vs final metrics
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

# Improved sysbench function with better capture
run_sysbench() {
    log_message "  Running sysbench CPU benchmark..."

    local raw_output score
    raw_output=$(sysbench cpu --cpu-max-prime=15000 --threads=$(nproc) run 2>/dev/null)

    score=$(echo "$raw_output" | grep 'events per second:' | awk '{print $4}' | tr -d '\r\n')

    if [[ "$score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "  ${score} events/sec"
        printf "%s" "$score"  # Quiet, no trailing newline
    else
        log_message "  WARN: Sysbench failed to produce valid score."
        printf "N/A"
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
    # Wait for the specified duration
    sleep "$duration_s" 
    # Ensure it's stopped if sleep finishes first
    kill $stress_pid 2>/dev/null || true 
    wait $stress_pid 2>/dev/null || true
    log_message "  Stress level '$level' finished."
}


# RAPL power limit functions (VDD analog)
set_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Setting RAPL power limit to ${RAPL_POWER_LIMIT_W}W..."
        # Package limit (long term)
        powercap-set -p intel-rapl -z 0 -c 0 -l "$((RAPL_POWER_LIMIT_W * 1000000))" || log_message "  WARN: Failed to set RAPL limit."
        powercap-set -p intel-rapl -z 0 -c 1 -l "$((RAPL_POWER_LIMIT_W * 1000000))" || true # Short term
    fi
}

reset_rapl_limit() {
    if [ "$USE_RAPL" = true ] && command -v powercap-set &> /dev/null; then
        log_message "  Resetting RAPL power limit to default..."
        # Set a high limit (250W)
        local high_limit=$(( 250 * 1000000 ))
        powercap-set -p intel-rapl -z 0 -c 0 -l $high_limit &> /dev/null || true
        powercap-set -p intel-rapl -z 0 -c 1 -l $high_limit &> /dev/null || true
    fi
}

# --- Cleanup Function ---
cleanup() {
  log_message "[*] Cleaning up processes and files..."
  pkill -P $$ || true
  wait 2>/dev/null || true

  log_message "[*] Resetting system state..."
  reset_rapl_limit
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

# --- Compile Custom Stress Tools ---
compile_hammer() {
    log_message "[*] Compiling enhanced hammer tool..."
    # Write hammer.c source to file
    cat > hammer.c << 'HAMMER_EOF'
/* Hammer source code content would go here - See hammer.c version above */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

// Configuration struct for hammer parameters
typedef struct {
    size_t reps;             // Number of hammering iterations
    size_t row_size;         // Size of each memory row (usually 4096 for page size)
    size_t distance;         // Distance between hammered addresses
    size_t pattern_length;   // Length of the access pattern
    uint8_t check_corruption; // Whether to check for memory corruption
    uint8_t perform_write;   // Whether to perform writes (more aggressive)
    uint8_t verbose;         // Verbose output
    size_t thread_count;     // Number of threads to use
} hammer_config_t;

// Get time in nanoseconds (for timing measurements)
uint64_t get_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Thread data structure
typedef struct {
    void *mem_region;
    size_t offset;
    size_t pattern_length;
    size_t distance;
    size_t reps;
    uint8_t perform_write;
    uint8_t check_corruption;
    uint8_t *ref_data;
    uint8_t *corruption_detected;
} hammer_thread_data_t;

// Enhanced hammering function with various access patterns
void *hammer_thread(void *arg) {
    hammer_thread_data_t *data = (hammer_thread_data_t *)arg;
    
    // Create array of addresses to hammer based on pattern
    volatile uint64_t **addresses = malloc(data->pattern_length * sizeof(uint64_t*));
    for (size_t i = 0; i < data->pattern_length; i++) {
        addresses[i] = (uint64_t*)((char*)data->mem_region + data->offset + (i * data->distance));
    }
    
    // Alternate access pattern for more aggressive stress (NS-RAM analogy: multiple pulse patterns)
    int pattern_selector = 0;
    const int NUM_PATTERNS = 3;
    
    // Main hammering loop (NS-RAM analogy: pulse train with variable amplitudes)
    for (size_t i = 0; i < data->reps; i++) {
        // Change pattern every 1000 iterations to create variable stress (NS-RAM: pulse width/amplitude modulation)
        if (i % 1000 == 0) {
            pattern_selector = (pattern_selector + 1) % NUM_PATTERNS;
        }
        
        // Flush cache lines (NS-RAM analogy: depleting charge carriers)
        for (size_t j = 0; j < data->pattern_length; j++) {
            _mm_clflush((const void *)addresses[j]);
        }
        _mm_mfence(); // Ensure flush completes
        _mm_sfence(); // Store fence
        
        // Access pattern 0: Sequential (NS-RAM: regular pulse train)
        if (pattern_selector == 0) {
            for (size_t j = 0; j < data->pattern_length; j++) {
                if (data->perform_write) {
                    *(addresses[j]) = i; // Write operation (NS-RAM: stronger pulse)
                } else {
                    volatile uint64_t dummy = *(addresses[j]); // Read operation (NS-RAM: weaker pulse)
                    (void)dummy; // Prevent optimization
                }
                _mm_mfence();
            }
        }
        // Access pattern 1: Alternating (NS-RAM: bipolar pulse)
        else if (pattern_selector == 1) {
            for (size_t j = 0; j < data->pattern_length; j += 2) {
                if (j+1 < data->pattern_length) {
                    if (data->perform_write) {
                        *(addresses[j]) = i;
                        *(addresses[j+1]) = ~i; // Inverted value (NS-RAM: bipolar pulse) 
                    } else {
                        volatile uint64_t dummy1 = *(addresses[j]);
                        volatile uint64_t dummy2 = *(addresses[j+1]);
                        (void)dummy1; (void)dummy2;
                    }
                    _mm_mfence();
                }
            }
        }
        // Access pattern 2: Reverse (NS-RAM: reverse pulse train)
        else {
            for (int j = data->pattern_length - 1; j >= 0; j--) {
                if (data->perform_write) {
                    *(addresses[j]) = i;
                } else {
                    volatile uint64_t dummy = *(addresses[j]);
                    (void)dummy;
                }
                _mm_mfence();
            }
        }
        
        // Check for corruption (NS-RAM analogy: detecting state changes)
        if (data->check_corruption && data->ref_data && data->corruption_detected && (i % 100000 == 0)) {
            for (size_t j = 0; j < data->pattern_length; j++) {
                for (size_t k = 0; k < 64; k += 8) { // Check first 64 bytes of each page
                    uint8_t expected = data->ref_data[data->offset + j * data->distance + k];
                    uint8_t actual = ((uint8_t*)data->mem_region)[data->offset + j * data->distance + k];
                    if (expected != actual && !(*data->corruption_detected)) {
                        *data->corruption_detected = 1;
                        printf("[Thread %zu] Corruption at %p: Expected %u, got %u\n", 
                              data->offset/data->distance, 
                              (void*)((uint8_t*)data->mem_region + data->offset + j * data->distance + k),
                              expected, actual);
                    }
                }
            }
        }
    }
    
    free(addresses);
    return NULL;
}

int main(int argc, char *argv[]) {
    // Default configuration (NS-RAM analogy: base transistor parameters)
    hammer_config_t config = {
        .reps = 20000000,          // Higher iteration count (NS-RAM: longer stress cycles)
        .row_size = 4096,          // Page size (NS-RAM: transistor geometry)
        .distance = 8192,          // Doubled distance between addresses (NS-RAM: wider spacing)
        .pattern_length = 4,       // Increased pattern length (NS-RAM: multi-cell effects)
        .check_corruption = 1,     // Check for bit flips (NS-RAM: state transitions)
        .perform_write = 1,        // More aggressive with writes (NS-RAM: stronger pulses)
        .verbose = 1,
        .thread_count = 2          // Multi-threaded (NS-RAM: parallel cell operation)
    };
    
    // Parse command-line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--reps") == 0 && i+1 < argc) {
            config.reps = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--row-size") == 0 && i+1 < argc) {
            config.row_size = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--distance") == 0 && i+1 < argc) {
            config.distance = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--pattern-length") == 0 && i+1 < argc) {
            config.pattern_length = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--check-corruption") == 0 && i+1 < argc) {
            config.check_corruption = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--perform-write") == 0 && i+1 < argc) {
            config.perform_write = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--thread-count") == 0 && i+1 < argc) {
            config.thread_count = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--verbose") == 0 && i+1 < argc) {
            config.verbose = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("NSR-AM Memory Hammer v2.0 - System-Level Analogy for Transistor Stress\n");
            printf("Usage: %s [options]\n", argv[0]);
            printf("Options:\n");
            printf("  --reps N              Hammering iterations (Default: 20M)\n");
            printf("  --row-size N          Memory row size in bytes (Default: 4096)\n");
            printf("  --distance N          Distance between addresses (Default: 8192)\n");
            printf("  --pattern-length N    Access pattern length (Default: 4)\n");
            printf("  --check-corruption N  Check for memory corruption 0/1 (Default: 1)\n");
            printf("  --perform-write N     Perform write operations 0/1 (Default: 1)\n");
            printf("  --thread-count N      Number of parallel threads (Default: 2)\n");
            printf("  --verbose N           Verbose output 0/1 (Default: 1)\n");
            return 0;
        }
    }
    
    // Calculate total memory size needed
    size_t total_size = config.row_size * config.pattern_length * config.thread_count * 2;
    
    // Allocate and initialize memory
    void *mem = aligned_alloc(config.row_size, total_size);
    if (!mem) {
        perror("Memory allocation failed");
        return 1;
    }
    
    // Initialize test pattern and reference copy
    uint8_t *ref_data = NULL;
    if (config.check_corruption) {
        ref_data = malloc(total_size);
        if (!ref_data) {
            perror("Reference data allocation failed");
            free(mem);
            return 1;
        }
        
        // Create pattern with recognizable data
        for (size_t i = 0; i < total_size; i++) {
            ref_data[i] = ((i * 37) & 0xFF);  // Easily detectable pattern
            ((uint8_t*)mem)[i] = ref_data[i]; // Copy to main memory
        }
    }
    
    if (config.verbose) {
        printf("NS-RAM Memory Hammer v2.0\n");
        printf("-------------------------\n");
        printf("Configuration:\n");
        printf("  Repetitions: %zu million\n", config.reps / 1000000);
        printf("  Pattern length: %zu addresses\n", config.pattern_length);
        printf("  Write operations: %s\n", config.perform_write ? "Enabled" : "Disabled");
        printf("  Threads: %zu\n", config.thread_count);
        printf("  Memory allocated: %zu MB\n", total_size / (1024*1024));
    }
    
    // Create and launch threads
    pthread_t *threads = malloc(config.thread_count * sizeof(pthread_t));
    hammer_thread_data_t *thread_data = malloc(config.thread_count * sizeof(hammer_thread_data_t));
    uint8_t corruption_detected = 0;
    
    uint64_t start_ns = get_ns();
    
    for (size_t t = 0; t < config.thread_count; t++) {
        thread_data[t].mem_region = mem;
        thread_data[t].offset = t * config.pattern_length * config.distance;
        thread_data[t].pattern_length = config.pattern_length;
        thread_data[t].distance = config.distance;
        thread_data[t].reps = config.reps;
        thread_data[t].perform_write = config.perform_write;
        thread_data[t].check_corruption = config.check_corruption;
        thread_data[t].ref_data = ref_data;
        thread_data[t].corruption_detected = &corruption_detected;
        
        pthread_create(&threads[t], NULL, hammer_thread, &thread_data[t]);
    }
    
    // Wait for all threads to complete
    for (size_t t = 0; t < config.thread_count; t++) {
        pthread_join(threads[t], NULL);
    }
    
    uint64_t end_ns = get_ns();
    double elapsed_s = (end_ns - start_ns) / 1000000000.0;
    
    if (config.verbose) {
        printf("\nResults:\n");
        printf("  Execution time: %.2f seconds\n", elapsed_s);
        printf("  Hammer rate: %.2f million iterations/sec\n", config.reps / elapsed_s / 1000000.0);
        
        if (config.check_corruption) {
            if (corruption_detected) {
                printf("  STATUS: CORRUPTION DETECTED\n");
                printf("  Analog: Memory state transition observed (comparable to NS-RAM state change)\n");
            } else {
                printf("  STATUS: No corruption detected\n");
                printf("  Analog: Memory maintained stable state (comparable to sub-threshold NS-RAM))\n");
            }
        }
    }
    
    // Clean up
    free(mem);
    free(threads);
    free(thread_data);
    if (ref_data) free(ref_data);
    
    return corruption_detected ? 2 : 0;
}

HAMMER_EOF

    gcc -O2 -march=native -pthread -o hammer hammer.c || {
        log_message "!!! Hammer compilation failed!"
        return 1
    }
    log_message "[+] Hammer compilation successful"
    return 0
}

compile_spec_havoc() {
    log_message "[*] Compiling enhanced spec_havoc tool..."
    # Write spec_havoc.S source to file
    cat > spec_havoc.S << 'SPEC_HAVOC_EOF'
.section .text
.global _start

# NS-RAM Analog: This assembly code stresses different CPU components
# to simulate transistor stress patterns within the NS-RAM architecture.
# The variable instruction mix simulates different voltage/current stresses.

_start:
    # Initialize AVX registers (NS-RAM analog: Initial charge state)
    vmovaps %ymm0, %ymm1
    vmovaps %ymm0, %ymm2
    vmovaps %ymm0, %ymm3
    vmovaps %ymm0, %ymm4
    vmovaps %ymm0, %ymm5
    vmovaps %ymm0, %ymm6
    vmovaps %ymm0, %ymm7
    
    # Initialize phase counter (NS-RAM analog: Pulse phase)
    xor %r12, %r12                # Current phase (0-3)
    mov $1000000000, %r13         # Max iterations
    xor %r14, %r14                # Iteration counter
    
    # Initialize test values
    mov $0x5555555555555555, %rax
    mov $0xaaaaaaaaaaaaaaaa, %rbx
    mov $0x3333333333333333, %rcx
    mov $0xcccccccccccccccc, %rdx
    
.main_loop:
    # Check if we should change phase (NS-RAM analog: LIF phase changes)
    inc %r14
    cmp %r13, %r14
    jge .exit
    test $0x1FFF, %r14           # Change phase every 8192 iterations
    jnz .skip_phase_change
    
    # Cycle through phases
    inc %r12
    and $3, %r12                  # Keep in range 0-3
    
.skip_phase_change:
    # Branch to appropriate phase
    cmp $0, %r12
    je .phase0
    cmp $1, %r12
    je .phase1
    cmp $2, %r12
    je .phase2
    jmp .phase3

.phase0:
    # Phase 0: FPU/Vector-intense stress (NS-RAM analog: Strong pulse)
    # Simulate potentiation phase with heavy AVX operations
    vaddps %ymm0, %ymm1, %ymm2
    vmulps %ymm2, %ymm3, %ymm4
    vdivps %ymm4, %ymm5, %ymm6    # Division is particularly stressful
    vaddps %ymm6, %ymm7, %ymm0
    vaddps %ymm0, %ymm1, %ymm2
    vmulps %ymm2, %ymm3, %ymm4
    vdivps %ymm4, %ymm5, %ymm6
    vaddps %ymm6, %ymm7, %ymm1
    jmp .continue

.phase1:
    # Phase 1: Integer ALU operations (NS-RAM analog: Medium pulse)
    # Simulate depression phase with integer operations
    imul %rax, %rbx
    add %rbx, %rcx
    xor %rcx, %rdx
    ror $11, %rax
    imul %rdx, %rax
    add %rax, %rbx
    xor %rbx, %rcx
    ror $13, %rdx
    imul %rcx, %rdx
    jmp .continue

.phase2:
    # Phase 2: Branch prediction stress (NS-RAM analog: Variable pulse)
    # Simulate chaotic pulse pattern with unpredictable branches
    test $1, %r14
    jz .branch_path1
    test $2, %r14
    jnz .branch_path2
    test $4, %r14
    jz .branch_path3
    test $8, %r14
    jnz .branch_path4
    jmp .branch_done
    
.branch_path1:
    add $1, %rax
    jmp .branch_done
.branch_path2:
    sub $1, %rbx
    jmp .branch_done
.branch_path3:
    xor $0xFF, %rcx
    jmp .branch_done
.branch_path4:
    rol $1, %rdx
    
.branch_done:
    jmp .continue

.phase3:
    # Phase 3: Mixed load/store operations (NS-RAM analog: Recovery phase)
    # Simulate recovery with memory operations
    push %rax
    push %rbx
    push %rcx
    push %rdx
    
    # Some arithmetic between loads/stores 
    add (%rsp), %rax
    xor 8(%rsp), %rbx
    sub 16(%rsp), %rcx
    
    # Restore stack
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax

.continue:
    # Back to main loop - check counter periodically (NS-RAM: cycle measurement)
    test $0xFFFFF, %r14          # Show progress every ~1M iterations
    jnz .main_loop
    
    # Check if we should terminate
    cmp %r13, %r14
    jl .main_loop
    
.exit:
    # Exit syscall
    mov $60, %rax                 # syscall: exit
    xor %rdi, %rdi                # status: 0
    syscall
SPEC_HAVOC_EOF

    as spec_havoc.S -o spec_havoc.o && ld spec_havoc.o -o spec_havoc || {
        log_message "!!! Spec Havoc assembly/linking failed!"
        return 1
    }
    log_message "[+] Spec Havoc compilation successful"
    return 0
}

# =============================================================
#               INITIAL SETUP & BASELINE
# =============================================================
log_message "=== Advanced NS-RAM System Analogy Stress Test v2.1 ==="
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

log_message "[*] Disabling ASLR (stability control)..."
echo 0 > /proc/sys/kernel/randomize_va_space

sleep 1
baseline_freq=$(get_cpu_freq)
baseline_temp=$(get_cpu_temp)
log_message "Initial frequency: ${baseline_freq} KHz"
log_message "Initial temp: ${baseline_temp} C"

log_message "[*] Compiling custom stress tools..."
compile_hammer
compile_spec_havoc

log_message "[*] Running Baseline Performance (Sysbench)..."
baseline_bench_score=$(run_sysbench)
current_bench_score=$baseline_bench_score # Initialize current score
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
    log_message "Parameters: Amplitude='$NEURON_PULSE_AMPLITUDE', τon=${NEURON_PULSE_INTERVAL_ON_S}s, τoff=${NEURON_PULSE_INTERVAL_OFF_S}s, Cycles=$NEURON_CYCLES"
    log_message "NS-RAM Paper Analog: Testing Leaky Integrate & Fire neuron behavior (Fig. 2a,b)"
    
    total_neuron_duration=$(( NEURON_CYCLES * (NEURON_PULSE_INTERVAL_ON_S + NEURON_PULSE_INTERVAL_OFF_S) ))
    log_message "Estimated duration: ${total_neuron_duration}s"

    failed_integrate=false
    for cycle in $(seq 1 $NEURON_CYCLES); do
        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Applying Pulse (τon)..."
        temp_before_pulse=$(get_cpu_temp)
        
        # Execute stress and spec_havoc in parallel for pulse phase
        apply_stress "$NEURON_PULSE_AMPLITUDE" "$NEURON_PULSE_INTERVAL_ON_S" &
        stress_pid=$!
        
        # Run spec_havoc for more aggressive stressing during pulse (if compiled)
        if [ -x "./spec_havoc" ]; then
            timeout "${NEURON_PULSE_INTERVAL_ON_S}s" ./spec_havoc &>/dev/null &
            havoc_pid=$!
        fi
        
        wait $stress_pid
        [ -n "${havoc_pid:-}" ] && { kill $havoc_pid 2>/dev/null || true; wait $havoc_pid 2>/dev/null || true; }
        
        temp_after_pulse=$(get_cpu_temp)
        freq_after_pulse=$(get_cpu_freq)
        log_message "  Pulse End: Temp=${temp_after_pulse}C (Δ+$(( temp_after_pulse - temp_before_pulse ))C), Freq=${freq_after_pulse}KHz"

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

        log_message "Neuron Cycle $cycle/$NEURON_CYCLES: Recovery phase (τoff - Leaking)..."
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
             # Consider recovered if within ~5% of baseline
             if [ $freq_diff -lt $(( baseline_freq / 20 )) ]; then
                 freq_recovered="true"
             else
                 freq_recovered="false (Δ: ${freq_diff}KHz)"
             fi
         fi

        log_message "  Recovery End: Temp=${temp_after_recovery}C (Δ-${temp_drop}C), Freq=${freq_after_recovery}KHz (Recovered: ${freq_recovered})"
        log_message "  Recovery Time τr: ${recovery_duration}s (NS-RAM VG2 Analog)"

        # Save recovery phase data
        save_neuron_data "$cycle" "recovery" "$temp_after_recovery" "$freq_after_recovery" "$recovery_duration" "0"

        # Check recovery adequacy
        if [[ "$temp_drop" != "N/A" && $temp_drop -lt 5 ]] && [[ "$cycle" -gt 1 ]]; then
             log_message "  [!] WARN: Low temperature drop during recovery (< 5C). System may be heat-saturated."
        fi
         if [[ "$freq_recovered" == "false"* ]]; then
             log_message "  [!] WARN: Frequency failed to recover near baseline during OFF period."
         fi

    done # End Neuron Cycles

    if [ "$failed_integrate" = true ]; then
        log_message "[!!!] NEURON MODE FAILED: System instability detected (critical errors)."
    else
        log_message "[✓] NEURON MODE COMPLETED: System processed $NEURON_CYCLES pulses. LIF behavior observed."
    fi
fi


# =============================================================
#            MODE: SYNAPSE (Short-Term Plasticity Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_SHORT" ]; then
    log_message "\n[3] SYNAPSE MODE TEST (Short-Term Plasticity Analogy)"
    log_message "Parameters: POT_Load='$SYN_ST_POTENTIATION_LOAD', DEP_Load='$SYN_ST_DEPRESSION_LOAD', Pulse=${SYN_ST_PULSE_DURATION_S}s"
    log_message "POT Pulses=$SYN_ST_POT_PULSES, DEP Pulses=$SYN_ST_DEP_PULSES, Forget=${SYN_ST_FORGET_DURATION_S}s, Cycles=$SYN_ST_CYCLES"
    log_message "NS-RAM Paper Analog: Testing STP dynamics (Fig. 2c,d and 3a)"

    for cycle in $(seq 1 $SYN_ST_CYCLES); do
        log_message "\nShort-Term Cycle $cycle/$SYN_ST_CYCLES: Starting Potentiation..."
        sleep 2
        
        # Measure before potentiation
        current_bench_score=$(run_sysbench)
        log_message "  Cycle Start State (Sysbench Score): ${current_bench_score} events/sec"
        
        # Save initial state for this cycle
        save_synaptic_short_data "$cycle" "start" "0" "$current_bench_score"

        # Potentiation Phase (Facilitation Analogy)
        for p_pulse in $(seq 1 $SYN_ST_POT_PULSES); do
             log_message "  Potentiation Pulse $p_pulse/$SYN_ST_POT_PULSES (NS-RAM: VPOT)..."
             
             # Use hammer tool for potentiation if available (more aggressive)
             if [ -x "./hammer" ]; then
                 log_message "  Running memory hammer (VPOT analog) during potentiation..."
                 ./hammer --reps $HAMMER_ITERATIONS --pattern-length $HAMMER_PATTERN_LENGTH \
                          --perform-write $HAMMER_WRITE_OPS --thread-count $HAMMER_THREAD_COUNT \
                          --verbose 0 &>/dev/null &
                 hammer_pid=$!
             fi
             
             # Apply regular stress
             apply_stress "$SYN_ST_POTENTIATION_LOAD" "$SYN_ST_PULSE_DURATION_S"
             
             # Kill hammer if still running
             if [ -n "${hammer_pid:-}" ]; then
                 kill $hammer_pid 2>/dev/null || true
                 wait $hammer_pid 2>/dev/null || true
             fi
             
             sleep 2 # Brief pause between pulses
             
             current_bench_score=$(run_sysbench)
             log_message "    State after POT Pulse $p_pulse: ${current_bench_score} events/sec"
             
             # Save potentiation data
             save_synaptic_short_data "$cycle" "potentiation" "$p_pulse" "$current_bench_score"
        done

        log_message "Short-Term Cycle $cycle/$SYN_ST_CYCLES: Starting Depression..."
        # Depression Phase
        for d_pulse in $(seq 1 $SYN_ST_DEP_PULSES); do
             log_message "  Depression Pulse $d_pulse/$SYN_ST_DEP_PULSES (NS-RAM: VDEP)..."
             apply_stress "$SYN_ST_DEPRESSION_LOAD" "$SYN_ST_PULSE_DURATION_S"
             sleep 2
             
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
             if (( elapsed_forget % 5 == 0 )); then  # Check every 5 seconds
                 current_bench_score=$(run_sysbench)
                 log_message "  Forget Time +${elapsed_forget}s: State=${current_bench_score} events/sec"
                 
                 # Save forgetting data
                 save_synaptic_short_data "$cycle" "forget" "$elapsed_forget" "$current_bench_score"
             fi
             
             sleep 1
        done
        log_message "  Forgetting phase complete."
        sleep 2
        
        # Final score after forgetting
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
    log_message "[✓] SYNAPSE SHORT-TERM MODE COMPLETED. STP dynamics observed."
fi

# =============================================================
#            MODE: SYNAPSE (Long-Term Plasticity Analogy)
# =============================================================
if [ "$MODE" == "ALL" ] || [ "$MODE" == "SYNAPSE_LONG" ]; then
    log_message "\n[4] SYNAPSE MODE TEST (Long-Term Plasticity Analogy)"
    log_message "Parameters: POT_Load='$SYN_LT_POTENTIATION_LOAD', DEP_Load='$SYN_LT_DEPRESSION_LOAD', Pulse=${SYN_LT_PULSE_DURATION_S}s"
    log_message "Bipolar Cycles=$SYN_LT_CYCLES, Retention Test=${SYN_LT_RETENTION_S}s"
    log_message "NS-RAM Paper Analog: Testing LTP behavior (Fig. 3b-d and 4)"
    
    ltp_errors=false
    ltp_corruption=false

    for cycle in $(seq 1 $SYN_LT_CYCLES); do
        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Applying Intense Potentiation Pulse..."
        
        # Mix of stress-ng and hammer for more intense stress during potentiation
        apply_stress "$SYN_LT_POTENTIATION_LOAD" "$SYN_LT_PULSE_DURATION_S" &
        stress_pid=$!
        
        # Run hammer in background if available
        if [ -x "./hammer" ] && [ $((cycle % 5)) -eq 0 ]; then  # Run hammer every 5 cycles
            log_message "  Adding hammer stress during cycle $cycle (NS-RAM: Charge-trapping analog)"
            ./hammer --reps $HAMMER_ITERATIONS --pattern-length $HAMMER_PATTERN_LENGTH \
                     --perform-write $HAMMER_WRITE_OPS --thread-count $HAMMER_THREAD_COUNT \
                     --verbose 0 &>/dev/null &
            hammer_pid=$!
        fi
        
        wait $stress_pid
        if [ -n "${hammer_pid:-}" ]; then
            kill $hammer_pid 2>/dev/null || true
            wait $hammer_pid 2>/dev/null || true
        fi
        
        bench_score_pot=$(run_sysbench)
        temp_after_pot=$(get_cpu_temp)
        
        # Save potentiation data
        error_detected=0
        corruption_detected=0
        save_synaptic_long_data "$cycle" "potentiation" "$temp_after_pot" "$bench_score_pot" "$error_detected" "$corruption_detected"
        
        sleep 1 # Short pause

        log_message "Long-Term Cycle $cycle/$SYN_LT_CYCLES: Applying Depression Phase..."
        apply_stress "$SYN_LT_DEPRESSION_LOAD" "$SYN_LT_PULSE_DURATION_S"
        temp_after_dep=$(get_cpu_temp)
        bench_score_dep=$(run_sysbench)
        
        # Save depression data
        error_detected=0
        corruption_detected=0
        
        # Check for critical errors
        if dmesg | tail -n 20 | grep -q -iE 'MCE|uncorrected|critical|panic'; then
             log_message "  [!!!] FAILURE: Critical error detected during Long-Term cycle $cycle!"
             error_detected=1
             ltp_errors=true
        fi
        
        # Periodic data integrity check
        if (( cycle % 10 == 0 )); then
             log_message "  Performing integrity check (Cycle $cycle)..."
             sync
             md5_now=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
             if [ "$md5_orig" != "$md5_now" ]; then
                 log_message "  [!!!] FAILURE: Data corruption detected! (NS-RAM: Catastrophic state transition)"
                 corruption_detected=1
                 ltp_corruption=true
             else
                 log_message "  Data integrity verified (NS-RAM: State integrity maintained)"
             fi
        fi
        
        save_synaptic_long_data "$cycle" "depression" "$temp_after_dep" "$bench_score_dep" "$error_detected" "$corruption_detected"
        if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then
            break # Stop cycling on critical error or corruption
        fi
        
        # Progress indicator for long runs
        if [ $((cycle % 10)) -eq 0 ]; then
            log_message "  Completed $cycle/$SYN_LT_CYCLES cycles"
        fi
        
        sleep 1
    done # End Long-Term Cycles

    if [ "$ltp_errors" = false ] && [ "$ltp_corruption" = false ]; then
        log_message "Long-Term Cycling Phase complete ($SYN_LT_CYCLES cycles)."
        log_message "Starting Retention Test Phase (${SYN_LT_RETENTION_S}s idle, NS-RAM: Weight retention test)..."
        
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
                
                log_message "  Retention +${elapsed_retention}s: Temp=${temp_current}C, Score=${bench_score_current}"
                
                save_synaptic_long_data "$SYN_LT_CYCLES" "retention_progress" "$temp_current" "$bench_score_current" "0" "0"
            fi
            
            sleep 1
        done
        
        log_message "Retention Test: Final Checks..."
        # Final MD5 Check
        sync
        md5_after_retention=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
        log_message "  Hash after retention: $md5_after_retention"
        error_detected=0
        corruption_detected=0
        
        if [ "$md5_orig" != "$md5_after_retention" ]; then
             log_message "  [!!!] FAILURE: Data corruption detected after retention! (NS-RAM: Unstable state)"
             corruption_detected=1
             ltp_corruption=true
        else
             log_message "  [✓] Data integrity preserved after retention (NS-RAM: Stable state retention)"
        fi

        # Final dmesg check for delayed errors
        if dmesg | tail -n 100 | grep -q -iE 'MCE|uncorrected|critical|panic'; then
             log_message "  [!!!] FAILURE: Critical errors detected in dmesg post-retention!"
             error_detected=1
             ltp_errors=true
        else
             log_message "  [✓] No new critical errors in dmesg post-retention"
        fi

        # Final performance check
        final_ltp_score=$(run_sysbench)
        final_ltp_temp=$(get_cpu_temp)
        log_message "  Final Performance: ${final_ltp_score} events/sec (Baseline: ${baseline_bench_score})"
        
        # Save final retention data
        save_synaptic_long_data "$SYN_LT_CYCLES" "retention_end" "$final_ltp_temp" "$final_ltp_score" "$error_detected" "$corruption_detected"
        
        if [[ "$final_ltp_score" =~ ^[0-9]+(\.[0-9]+)?$ && "$baseline_bench_score" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            final_recovery_percent=$(echo "scale=2; $final_ltp_score * 100 / $baseline_bench_score" | bc)
            log_message "  Final Recovery vs Baseline: ${final_recovery_percent}%"
            if (( $(echo "$final_recovery_percent < 90" | bc -l) )); then
                log_message "  [!] WARN: Persistent performance degradation observed (NS-RAM: Memory effect)"
            fi
        fi
    fi # End if no early failure

    if [ "$ltp_errors" = true ] || [ "$ltp_corruption" = true ]; then
         log_message "[!!!] SYNAPSE LONG-TERM MODE FAILED: Persistent errors/corruption observed"
         log_message "      (NS-RAM Analog: Irreversible state change/damage)"
    else
         log_message "[✓] SYNAPSE LONG-TERM MODE COMPLETED: LTP behavior observed"
    fi
fi


# =============================================================
#                   FINAL ANALYSIS & VERDICT
# =============================================================
log_message "\n[5] FINAL SYSTEM STATE & OVERALL EVALUATION"

final_freq=$(get_cpu_freq)
final_temp=$(get_cpu_temp)
final_bench_score=$(run_sysbench)
log_message "Final frequency: ${final_freq} KHz (Baseline: ${baseline_freq} KHz)"
log_message "Final temp: ${final_temp} C (Baseline: ${baseline_temp} C)"
log_message "Final Sysbench Score: ${final_bench_score} events/sec (Baseline: ${baseline_bench_score} events/sec)"

final_md5=$(md5sum "$TEST_DATA_FILE" | awk '{print $1}')
log_message "Final MD5 Check: $final_md5 (Original: $md5_orig)"

# Save final system summary data
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

# Overall Verdict
overall_success=true
if grep -q -iE '\[!!!\] FAILURE:|DATA CORRUPTION DETECTED!' "$LOGFILE"; then
    overall_success=false
fi

log_message "\n--- OVERALL VERDICT (NS-RAM Analogy Interpretation) ---"
if [ "$overall_success" = true ]; then
    if grep -q '\[!\] WARN:' "$LOGFILE"; then
         log_message "⚠️  SYSTEM STRESSED BUT STABLE: Tests completed without critical failures, but with warnings."
         log_message "   NS-RAM Analog: Device operated near threshold, showing stress effects but no permanent failure."
    else
         log_message "✅ SYSTEM RESILIENT: Completed all tests successfully with strong recovery."
         log_message "   NS-RAM Analog: Device operated within robust operating region, maintaining state integrity."
    fi
else
     log_message "❌ SYSTEM FAILURE: Critical errors or data corruption occurred."
     log_message "   NS-RAM Analog: Device threshold exceeded, resulting in irreversible state change or damage."
fi

log_message "Test completed at: $(date)"
log_message "Log file saved to: $LOGFILE"
log_message "Data directory for plotting: $DATA_DIR"

# Cleanup is handled by the trap function on exit
exit 0
