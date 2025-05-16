#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for very verbose debugging of bash commands

SIM_DIR="./DRAM_Sim_Refactored"
mkdir -p "$SIM_DIR"
cd "$SIM_DIR"

# === Global Simulation Parameters (Define once, use everywhere) ===
PY_VDD="1.2"
PY_VWL_H="2.0"
PY_TSTOP="20e-6" # 20us
PY_PULSE_WIDTH="0.5e-6" # 0.5us
PY_NUM_SWITCHES="6"
PY_RANDOM_SEED="42" # Change for different random patterns

# === Step 1: Python to generate PWL patterns ===
cat > gen_patterns_refactored.py <<EOF
import numpy as np
import sys

# These parameters will be passed as command-line arguments for clarity
VDD = float(sys.argv[1])
VWL_H = float(sys.argv[2])
TSTOP = float(sys.argv[3])
PULSE_WIDTH = float(sys.argv[4])
NUM_SWITCHES = int(sys.argv[5])
RANDOM_SEED = int(sys.argv[6])

np.random.seed(RANDOM_SEED)

print(f"Python: VDD={VDD}, VWL_H={VWL_H}, TSTOP={TSTOP}, PULSE_WIDTH={PULSE_WIDTH}, NUM_SWITCHES={NUM_SWITCHES}, SEED={RANDOM_SEED}")

def generate_pulse_times(num_switches, tstop, pulse_width, min_start_time=0.5e-6):
    if num_switches == 0:
        return np.array([])

    # Max start time for any pulse so its definition (t_start + pulse_width + 1e-9) < tstop
    # Allow a small margin from tstop for the final "tstop 0" PWL point.
    effective_tstop_for_pulses = tstop - 1e-7 # Small margin
    max_allowable_pulse_end_point = effective_tstop_for_pulses

    # Upper bound for random generation of start times
    # Ensure that even the last pulse, if chosen at this upper bound, completes
    upper_bound_for_rand_starts = max_allowable_pulse_end_point - (pulse_width + 1e-9)

    if upper_bound_for_rand_starts <= min_start_time and num_switches > 0:
        print(f"Error: Time window too small for pulses. min_start_time={min_start_time}, upper_bound_for_rand_starts={upper_bound_for_rand_starts}")
        # Fallback to a single pulse if possible, or error
        if min_start_time < upper_bound_for_rand_starts:
             return np.array([min_start_time]) if num_switches >=1 else np.array([])
        else:
            print("Error: Cannot even fit one pulse.")
            return np.array([])


    times_raw = np.sort(np.random.uniform(min_start_time, upper_bound_for_rand_starts, num_switches))
    
    corrected_times = np.copy(times_raw)
    minimum_interval_between_starts = pulse_width + 1e-9 + 1e-10 # pulse defined up to t+pw+1e-9, add epsilon

    if num_switches > 1:
        for i in range(1, num_switches):
            required_next_start_time = corrected_times[i-1] + minimum_interval_between_starts
            if corrected_times[i] < required_next_start_time:
                corrected_times[i] = required_next_start_time
    
    # Final check if the (potentially pushed) last pulse is still valid
    if num_switches > 0 and (corrected_times[-1] + pulse_width + 1e-9 >= tstop):
        print(f"Error: Last pulse start time {corrected_times[-1]:.6e} results in pulse ending too late after corrections.")
        # This should ideally be prevented by a better upper_bound_for_rand_starts calculation based on num_switches
        # For now, we'll rely on the initial upper_bound_for_rand_starts being conservative.
        # If this error occurs, the PWL might be invalid.
        # Consider truncating or re-calculating. For now, just warn.
        print("Warning: Last pulse might be problematic due to time corrections pushing it near TSTOP.")

    return corrected_times

def pattern_to_pwl_string(times, pattern_values, high_voltage, p_width, sim_tstop):
    s = "0 0" # Start at t=0, V=0
    if not times.size or not pattern_values.size:
        s += f" {sim_tstop:.6e} 0"
        return s

    for t, val_is_high in zip(times, pattern_values):
        voltage = high_voltage if val_is_high else 0
        s += f" {t:.6e} {voltage}"
        s += f" {t + p_width:.6e} {voltage}"
        s += f" {t + p_width + 1e-9:.6e} 0" # Return to 0V after pulse
    
    # Ensure the PWL sequence explicitly defines behavior up to TSTOP
    # Find the time of the very last point defined by the pulses
    if times.size > 0:
        last_actual_point_time = times[-1] + p_width + 1e-9
        if last_actual_point_time < sim_tstop:
            s += f" {sim_tstop:.6e} 0" # Explicitly hold at 0 until TSTOP
    else: # No pulses, ensure it's 0 until TSTOP
        s += f" {sim_tstop:.6e} 0"
        
    return s

# Generate times for Cell 1
cell1_times = generate_pulse_times(NUM_SWITCHES, TSTOP, PULSE_WIDTH)
cell1_bl_pattern = np.random.randint(0, 2, size=len(cell1_times)) # Pattern matches actual number of pulses
cell1_wl_pattern = np.ones(len(cell1_times), dtype=int) # Wordline is always active during pulse

# Generate times for Cell 2 (e.g., slightly offset, or could be independent)
# For robustness, let's make Cell 2 times also independently generated for now,
# but ensure they don't excessively overlap with Cell 1 for clarity if desired.
# A simple offset is fine if checks are robust.
cell2_offset = 0.15e-6 # Smaller offset, ensure it's less than pulse_width to see effects
cell2_times_initial = cell1_times + cell2_offset
# Re-validate cell2_times against TSTOP after offset
valid_cell2_indices = np.where(cell2_times_initial + PULSE_WIDTH + 1e-9 < TSTOP)[0]
cell2_times = cell2_times_initial[valid_cell2_indices]

cell2_bl_pattern = np.random.randint(0, 2, size=len(cell2_times))
cell2_wl_pattern = np.ones(len(cell2_times), dtype=int)

# --- DEBUG: Force Cell 2 to a known simple pattern ---
# Comment this section out to use random patterns for Cell 2
if len(cell2_times) >= 1 : # Ensure there's at least one pulse time for cell 2
    print("DEBUG PYTHON: Forcing Cell 2 to a single '1' at its first available pulse time.")
    cell2_bl_pattern = np.zeros(len(cell2_times), dtype=int)
    cell2_bl_pattern[0] = 1 # First pulse is a '1'
    cell2_wl_pattern[0] = 1 # Ensure WL is also active (already default)
else:
    print("DEBUG PYTHON: No valid pulse times for Cell 2 after offset and TSTOP check, Cell 2 will be inactive.")
# --- End DEBUG section ---

print(f"Python: Cell 1 num pulses: {len(cell1_times)}")
print(f"Python: Cell 2 num pulses: {len(cell2_times)}")
print(f"Python: cell1_times = {cell1_times}")
print(f"Python: cell2_times = {cell2_times}")
print(f"Python: cell1_bl_pattern = {cell1_bl_pattern}")
print(f"Python: cell2_bl_pattern (potentially forced) = {cell2_bl_pattern}")


cell1_bl_pwl = pattern_to_pwl_string(cell1_times, cell1_bl_pattern, VDD, PULSE_WIDTH, TSTOP)
cell1_wl_pwl = pattern_to_pwl_string(cell1_times, cell1_wl_pattern, VWL_H, PULSE_WIDTH, TSTOP)
cell2_bl_pwl = pattern_to_pwl_string(cell2_times, cell2_bl_pattern, VDD, PULSE_WIDTH, TSTOP)
cell2_wl_pwl = pattern_to_pwl_string(cell2_times, cell2_wl_pattern, VWL_H, PULSE_WIDTH, TSTOP)

with open("cell_PWL_strings.txt", "w") as f:
    f.write(f"CELL1_BL_PWL='{cell1_bl_pwl}'\n")
    f.write(f"CELL1_WL_PWL='{cell1_wl_pwl}'\n")
    f.write(f"CELL2_BL_PWL='{cell2_bl_pwl}'\n")
    f.write(f"CELL2_WL_PWL='{cell2_wl_pwl}'\n")

print("Python: cell_PWL_strings.txt generated.")
EOF

echo "Bash: Generating PWL patterns using Python..."
python3 gen_patterns_refactored.py "$PY_VDD" "$PY_VWL_H" "$PY_TSTOP" "$PY_PULSE_WIDTH" "$PY_NUM_SWITCHES" "$PY_RANDOM_SEED"

echo "Bash: Sourcing PWL strings..."
if [ -f cell_PWL_strings.txt ]; then
    source cell_PWL_strings.txt
else
    echo "Bash: Error - cell_PWL_strings.txt not found!"
    exit 1
fi

# Check if variables were loaded
if [ -z "$CELL1_BL_PWL" ] || [ -z "$CELL2_BL_PWL" ]; then
    echo "Bash: Error - PWL shell variables are not set after sourcing. Python script might have failed or produced empty strings."
    exit 1
fi
echo "Bash: PWL strings sourced."
echo "Bash: CELL2_BL_PWL (in bash) starts with: $(echo $CELL2_BL_PWL | cut -c 1-50)..."
echo "Bash: CELL2_WL_PWL (in bash) starts with: $(echo $CELL2_WL_PWL | cut -c 1-50)..."


# === Step 2: Write SPICE netlist ===
# Parameters are directly substituted from Bash variables defined at the top.
# === Step 2: Write SPICE netlist ===
# Parameters are directly substituted from Bash variables.
# Corrected comments using ';' for end-of-line.
cat > dram_refactored.sp <<EOF
* DRAM Simulation - Refactored for Clarity
* Global Parameters defined in controlling script

.PARAM sim_vdd = $PY_VDD
.PARAM sim_vwl_h = $PY_VWL_H
.PARAM sim_c_cell = 30f
.PARAM sim_r_cap_leak = 3T
.PARAM sim_tran_tstep = 50n
.PARAM sim_c_couple = 25f
.PARAM sim_r_couple_leak = 100MEG

.model MyNMOS_Model NMOS (LEVEL=1 VTO=0.7 KP=120u W=0.1u L=0.1u) ; MOSFET Model

* --- Cell 1 ---
Vwl1 c1_wl 0 PWL($CELL1_WL_PWL)
Vbl1 c1_bl 0 PWL($CELL1_BL_PWL)
Cc1  c1_node 0 {sim_c_cell}      ; Cell 1 Storage Capacitor
Rcl1 c1_node 0 {sim_r_cap_leak}  ; Cell 1 Leakage Resistor
M1   c1_bl c1_wl c1_node 0 MyNMOS_Model

* --- Cell 2 ---
Vwl2 c2_wl 0 PWL($CELL2_WL_PWL)
Vbl2 c2_bl 0 PWL($CELL2_BL_PWL)
Cc2  c2_node 0 {sim_c_cell}      ; Cell 2 Storage Capacitor
Rcl2 c2_node 0 {sim_r_cap_leak}  ; Cell 2 Leakage Resistor
M2   c2_bl c2_wl c2_node 0 MyNMOS_Model ; Cell 2 Access Transistor

* --- Coupling ---
Ccouple_cells c1_node c2_node {sim_c_couple}
Rcouple_cells c1_node c2_node {sim_r_couple_leak}

* --- Analysis ---
.tran {sim_tran_tstep} $PY_TSTOP UIC ; UIC uses t=0 values and 0 for IC of L/C

.control
set wr_vecnames              ; Ensure variable names are in first line of wrdata output
set wr_singlescale           ; Use time as the single scale
run
wrdata dram_sim_output.csv v(c1_node) v(c2_node) v(c1_wl) v(c1_bl) v(c2_wl) v(c2_bl)
listing e                    ; Expanded listing of the circuit
* plot v(c1_node) v(c2_node) xlimit 0 $PY_TSTOP ylimit -0.1 [ \$PY_VDD * 1.2 ] ; Example plot (escape $ for literal)
quit
.endc

.end
EOF

echo "Bash: dram_refactored.sp netlist created."
echo "--- First few lines of dram_refactored.sp ---"
head -n 25 dram_refactored.sp
echo "--- Cell 2 definition in dram_refactored.sp ---"
grep -A 4 -e "Cell 2" dram_refactored.sp
echo "---------------------------------------------"


# === Step 3: Run Ngspice ===
echo "Bash: Running Ngspice..."
NGSPICE_LOG="ngspice_run.log"
ngspice -b dram_refactored.sp -o "$NGSPICE_LOG" || { 
    echo "Bash: Ngspice run failed!"
    echo "--- Ngspice Log ($NGSPICE_LOG) ---"
    cat "$NGSPICE_LOG"
    echo "---------------------------------"
    exit 1
}
echo "Bash: Ngspice run completed."
echo "--- Ngspice Log ($NGSPICE_LOG) (tail) ---"
tail -n 20 "$NGSPICE_LOG"
echo "---------------------------------"

if [ ! -s dram_sim_output.csv ]; then
    echo "Bash: Error - Ngspice output file dram_sim_output.csv is missing or empty."
    exit 1
fi
echo "Bash: Simulation output dram_sim_output.csv created."

# === Step 4: Python plot ===
cat > plot_refactored.py <<EOF
import matplotlib.pyplot as plt
import numpy as np
import sys

VDD_PLOT = float(sys.argv[1])
TSTOP_PLOT = float(sys.argv[2])
CSV_FILE = "dram_sim_output.csv"

try:
    # Ngspice with 'set wr_vecnames' puts variable names in the first row
    # and 'set wr_singlescale' means first column is time.
    data_raw = np.genfromtxt(CSV_FILE, names=True, skip_header=0) # skip_header=0 if names=True handles it.
                                                                # If no vecnames, use skip_header=N based on log
except Exception as e:
    print(f"Python Plot: Error loading {CSV_FILE}: {e}")
    # Try loading without names if that failed
    try:
        print(f"Python Plot: Trying to load {CSV_FILE} without assuming header names...")
        data_raw_alt = np.loadtxt(CSV_FILE) # Assumes no header, or header is pure comment
        # Assuming order: time, v(c1_node), v(c2_node), v(c1_wl), v(c1_bl), v(c2_wl), v(c2_bl)
        time_data = data_raw_alt[:,0]
        v_c1_node = data_raw_alt[:,1]
        v_c2_node = data_raw_alt[:,2]
        v_c1_wl = data_raw_alt[:,3]
        v_c1_bl = data_raw_alt[:,4]
        v_c2_wl = data_raw_alt[:,5]
        v_c2_bl = data_raw_alt[:,6]
    except Exception as e_alt:
        print(f"Python Plot: Secondary loading attempt also failed: {e_alt}")
        sys.exit(1)
else: # Original try succeeded
    time_data = data_raw['time'] # Or 'sweep' or whatever ngspice names the scale
    v_c1_node = data_raw['vc1_node'] # ngspice often removes parentheses and uses underscore
    v_c2_node = data_raw['vc2_node']
    v_c1_wl = data_raw['vc1_wl']
    v_c1_bl = data_raw['vc1_bl']
    v_c2_wl = data_raw['vc2_wl']
    v_c2_bl = data_raw['vc2_bl']


fig, axs = plt.subplots(3, 1, figsize=(12, 10), sharex=True)

axs[0].plot(time_data, v_c1_node, label="V(c1_node) - Cell 1 Store")
axs[0].plot(time_data, v_c2_node, label="V(c2_node) - Cell 2 Store (Forced 1st pulse '1')", linestyle='--')
axs[0].set_ylabel("Voltage (V)")
axs[0].legend()
axs[0].grid(True)
axs[0].set_ylim(-0.1, VDD_PLOT * 1.25)
axs[0].set_title(f"DRAM Cell Storage Nodes (Seed: {sys.argv[3]})")

axs[1].plot(time_data, v_c1_wl, label="V(c1_wl) - Cell 1 WL")
axs[1].plot(time_data, v_c2_wl, label="V(c2_wl) - Cell 2 WL", linestyle='--')
axs[1].set_ylabel("Voltage (V)")
axs[1].legend()
axs[1].grid(True)

axs[2].plot(time_data, v_c1_bl, label="V(c1_bl) - Cell 1 BL")
axs[2].plot(time_data, v_c2_bl, label="V(c2_bl) - Cell 2 BL", linestyle='--')
axs[2].set_ylabel("Voltage (V)")
axs[2].set_xlabel("Time (s)")
axs[2].legend()
axs[2].grid(True)

plt.tight_layout()
plt.savefig("dram_simulation_refactored.png")
print(f"Python Plot: Plot saved to dram_simulation_refactored.png")
# plt.show()
EOF

echo "Bash: Plotting simulation results..."
python3 plot_refactored.py "$PY_VDD" "$PY_TSTOP" "$PY_RANDOM_SEED"

echo "Bash: ✅ All steps completed. Output: dram_simulation_refactored.png"