#!/bin/bash

set -e
# set -x

SIM_DIR_BASE="DRAM_NN_Sim"
mkdir -p "$SIM_DIR_BASE"
cd "$SIM_DIR_BASE"

# === Global Simulation Parameters ===
PY_VDD="1.0" # Using 1.0V for easier mapping of weights (0 to 1) to voltage
PY_VWL_H="1.8" # Wordline high voltage
PY_TSTOP_WRITE_CYCLE="5e-6" # Time for one weight-write cycle in SPICE (long enough to charge cap)
PY_PULSE_WIDTH_WRITE="4e-6" # Duration BL and WL are active for writing
PY_C_CELL="50f" # Cell capacitance
PY_R_CAP_LEAK="100T" # Very high, ideal-ish leakage for now
PY_C_COUPLE="1f"   # Small coupling, assume cells are somewhat isolated
PY_R_COUPLE_LEAK="1000T"

# === Neural Network & Learning Parameters ===
NUM_EPOCHS="50" # Number of training iterations over the dataset
LEARNING_RATE="0.1"
# Bias will be a software variable in Python
# We'll use 2 DRAM cells for 2 weights (w1, w2) for an AND gate.

# Initialize a file to store weights (target voltages for DRAM) and bias
# These are the "ideal" weights the NN wants. SPICE will simulate storing them.
WEIGHTS_FILE="nn_weights.txt"
# Format: w1_target_voltage w2_target_voltage bias_software
# Initial weights (e.g., small random, or zero). Let's map NN weights (0-1) to V (0-VDD)
# Python will initialize this if it doesn't exist.
if [ ! -f "$WEIGHTS_FILE" ]; then
    echo "0.1 0.1 0.1" > "$WEIGHTS_FILE" # Initial guess: w1=0.1V, w2=0.1V, bias=0.1
fi

# File to track performance
PERFORMANCE_LOG="nn_performance_log.csv"
echo "epoch,w1_target,w2_target,bias,w1_actual_dram,w2_actual_dram,avg_epoch_error,accuracy" > "$PERFORMANCE_LOG"

# === Main Training Loop ===
for epoch in $(seq 1 "$NUM_EPOCHS"); do
    echo "************************************************************"
    echo "Bash: Starting Epoch $epoch / $NUM_EPOCHS"
    echo "************************************************************"

    CURRENT_SIM_DIR="epoch_${epoch}"
    mkdir -p "$CURRENT_SIM_DIR"
    cp "$WEIGHTS_FILE" "$CURRENT_SIM_DIR/" # Give current weights to python script

    # SPICE output from *previous* epoch (if any) which contains actual DRAM voltages
    PREVIOUS_SPICE_OUTPUT_CSV="../epoch_$((epoch-1))/dram_sim_output.csv"
    if [ "$epoch" -eq 1 ]; then
        PREVIOUS_SPICE_OUTPUT_CSV="NONE" # No previous output for the first epoch
    fi

    cd "$CURRENT_SIM_DIR"

    # === Step 1: Python for NN Logic & PWL Generation ===
    # Python script will:
    # 1. Read current target weights (and bias) from nn_weights.txt (copied from parent)
    # 2. Read ACTUAL DRAM voltages from PREVIOUS_SPICE_OUTPUT_CSV (if not first epoch) to use as current NN weights.
    #    If first epoch, use target weights as actual weights for the first forward pass.
    # 3. Perform one epoch of perceptron training (for AND gate).
    # 4. Calculate new TARGET weights (and bias).
    # 5. Save these new TARGET weights to nn_weights.txt (for the next epoch).
    # 6. Generate PWL strings to WRITE these new target weights into DRAM.
    # 7. Log performance.
    cat > nn_controller.py <<EOF
import numpy as np
import sys
import os

# Parameters from Bash
VDD = float(sys.argv[1])
VWL_H = float(sys.argv[2])
TSTOP_WRITE = float(sys.argv[3])
PULSE_WIDTH_WRITE = float(sys.argv[4])
LEARNING_RATE_PY = float(sys.argv[5])
WEIGHTS_FILE_PY = sys.argv[6] # Contains target w1, w2 (voltages) and bias (software)
PREVIOUS_SPICE_CSV = sys.argv[7]
PERFORMANCE_LOG_PY = sys.argv[8]
CURRENT_EPOCH = int(sys.argv[9])

print(f"Python NN Controller: Epoch {CURRENT_EPOCH}")
print(f"Python NN Controller: VDD={VDD}, VWL_H={VWL_H}, T_WRITE={TSTOP_WRITE}, PULSE_W_WRITE={PULSE_WIDTH_WRITE}")
print(f"Python NN Controller: LR={LEARNING_RATE_PY}, Weights File='{WEIGHTS_FILE_PY}', Prev SPICE='{PREVIOUS_SPICE_CSV}'")

# --- Perceptron & Training Data (AND gate) ---
# Inputs: x1, x2. Output: y
training_data = [
    (np.array([0, 0]), 0),
    (np.array([0, 1]), 0),
    (np.array([1, 0]), 0),
    (np.array([1, 1]), 1),
]

def activation_step(x):
    return 1 if x >= 0 else 0

# Load current TARGET weights and bias from file
# These are what we *intended* to write in the previous step (or initial values)
try:
    w_target_voltages_and_bias = np.loadtxt(WEIGHTS_FILE_PY)
    w1_target_voltage = w_target_voltages_and_bias[0]
    w2_target_voltage = w_target_voltages_and_bias[1]
    bias_software = w_target_voltages_and_bias[2]
    print(f"Python NN: Loaded TARGET w1_v={w1_target_voltage:.4f}V, w2_v={w2_target_voltage:.4f}V, bias={bias_software:.4f} from {WEIGHTS_FILE_PY}")
except Exception as e:
    print(f"Python NN: Error loading {WEIGHTS_FILE_PY}: {e}. Using defaults.")
    # These defaults should ideally match the initial ones in bash if file creation failed.
    w1_target_voltage = 0.1 * VDD # Map NN weight 0.1 to 0.1*VDD Volts
    w2_target_voltage = 0.1 * VDD
    bias_software = 0.1 # Bias is a direct value, not a voltage here

# Determine ACTUAL weights (voltages on DRAM) from previous SPICE run
w1_actual_dram_voltage = w1_target_voltage # Default to target if no SPICE data
w2_actual_dram_voltage = w2_target_voltage

if PREVIOUS_SPICE_CSV != "NONE" and os.path.exists(PREVIOUS_SPICE_CSV):
    try:
        # Assuming format: time, v(c1_node), v(c2_node) ...
        data_raw = np.genfromtxt(PREVIOUS_SPICE_CSV, names=True, skip_header=0)
        # Get the voltage at the END of the write cycle
        w1_actual_dram_voltage = data_raw['vc1_node'][-1]
        w2_actual_dram_voltage = data_raw['vc2_node'][-1]
        print(f"Python NN: Loaded ACTUAL DRAM voltages from {PREVIOUS_SPICE_CSV}: w1_dram={w1_actual_dram_voltage:.4f}V, w2_dram={w2_actual_dram_voltage:.4f}V")
    except Exception as e:
        print(f"Python NN: Error reading {PREVIOUS_SPICE_CSV}: {e}. Using target voltages as actual for this iteration.")
else:
    if CURRENT_EPOCH > 1 :
        print(f"Python NN: Warning - {PREVIOUS_SPICE_CSV} not found or not applicable. Using target voltages as actual.")
    else:
        print(f"Python NN: First epoch, using initial target voltages as actual for first forward pass.")


# --- Perform one epoch of training ---
# The weights used for prediction are the ACTUAL voltages read from DRAM (or targets if first pass/error)
# The weights updated are the TARGET voltages for the NEXT DRAM write
current_w1_for_prediction = w1_actual_dram_voltage
current_w2_for_prediction = w2_actual_dram_voltage

# These will be updated and become the new targets for DRAM
new_target_w1_voltage = w1_target_voltage # Start with previous target
new_target_w2_voltage = w2_target_voltage
new_bias_software = bias_software

total_error_this_epoch = 0
correct_predictions = 0

for x_vec, target_y in training_data:
    # Forward pass using actual DRAM values (or previous targets if no DRAM data yet)
    # Note: We are using voltages directly as weights.
    # If NN weights were e.g. -1 to 1, a mapping to 0-VDD would be needed.
    # Here, perceptron weights are >=0, mapping to voltage >=0.
    linear_combination = np.dot(x_vec, [current_w1_for_prediction, current_w2_for_prediction]) + new_bias_software
    prediction = activation_step(linear_combination)
    
    error = target_y - prediction
    total_error_this_epoch += abs(error)

    if error == 0:
        correct_predictions +=1

    # Update rule for TARGET voltages/bias
    # We adjust the target voltages for the DRAM.
    # The learning rate scales how much an error in prediction (based on actual DRAM state)
    # influences the *next target state* for the DRAM.
    new_target_w1_voltage += LEARNING_RATE_PY * error * x_vec[0]
    new_target_w2_voltage += LEARNING_RATE_PY * error * x_vec[1]
    new_bias_software += LEARNING_RATE_PY * error * 1 # Bias input is always 1

    # Clip target voltages to be within [0, VDD]
    new_target_w1_voltage = np.clip(new_target_w1_voltage, 0, VDD)
    new_target_w2_voltage = np.clip(new_target_w2_voltage, 0, VDD)
    # Bias can be anything, but let's keep it reasonable for typical perceptron behavior.
    new_bias_software = np.clip(new_bias_software, -2*VDD, 2*VDD)


avg_epoch_error = total_error_this_epoch / len(training_data)
accuracy = correct_predictions / len(training_data)
print(f"Python NN: Epoch {CURRENT_EPOCH} - Avg Error: {avg_epoch_error:.4f}, Accuracy: {accuracy:.2f}")
print(f"Python NN: Updated TARGETS: w1_v={new_target_w1_voltage:.4f}V, w2_v={new_target_w2_voltage:.4f}V, bias={new_bias_software:.4f}")

# Save new target weights and bias for the next main loop iteration (and for Python to pick up next time)
np.savetxt(WEIGHTS_FILE_PY, [new_target_w1_voltage, new_target_w2_voltage, new_bias_software], fmt='%.6e')
# Also copy to parent dir for next bash epoch to pick up
np.savetxt(f"../{WEIGHTS_FILE_PY.split('/')[-1]}", [new_target_w1_voltage, new_target_w2_voltage, new_bias_software], fmt='%.6e')


# Log performance
with open(f"../{PERFORMANCE_LOG_PY.split('/')[-1]}", "a") as f_log:
    f_log.write(f"{CURRENT_EPOCH},{new_target_w1_voltage:.6e},{new_target_w2_voltage:.6e},{new_bias_software:.6e},{w1_actual_dram_voltage:.6e},{w2_actual_dram_voltage:.6e},{avg_epoch_error:.6e},{accuracy:.6e}\n")

# --- Generate PWL strings for SPICE to write these NEW TARGET weights ---
# We want to write new_target_w1_voltage to c1_node and new_target_w2_voltage to c2_node.
# This involves setting the Bitline (BL) to the target voltage and pulsing the Wordline (WL).
# The pulse needs to start after t=0, e.g., at 0.1us, last for PULSE_WIDTH_WRITE, then BL/WL return to 0.
# Simulation TSTOP_WRITE should be slightly longer than pulse end.
rise_fall_time = 1e-9 # Arbitrary small rise/fall for PWL definition
pulse_start_time = 0.1e-6 # Start the write pulse a bit after t=0

# PWL string format: t1 v1 t2 v2 ...
# For Vbl: 0 0 -> pulse_start_time 0 -> (pulse_start_time + rise_fall_time) TARGET_VOLTAGE -> (pulse_start_time + PULSE_WIDTH_WRITE) TARGET_VOLTAGE -> (pulse_start_time + PULSE_WIDTH_WRITE + rise_fall_time) 0 -> TSTOP_WRITE 0
# For Vwl: 0 0 -> pulse_start_time 0 -> (pulse_start_time + rise_fall_time) VWL_H          -> (pulse_start_time + PULSE_WIDTH_WRITE) VWL_H          -> (pulse_start_time + PULSE_WIDTH_WRITE + rise_fall_time) 0 -> TSTOP_WRITE 0

def generate_voltage_pwl(target_voltage, t_pulse_start, t_pulse_width, t_rise_fall, t_sim_stop):
    # Ensure values are floats for formatting
    target_voltage = float(target_voltage)
    t_pulse_start = float(t_pulse_start)
    t_pulse_width = float(t_pulse_width)
    t_rise_fall = float(t_rise_fall)
    t_sim_stop = float(t_sim_stop)

    s = "0 0"
    s += f" {t_pulse_start:.6e} 0"
    s += f" {t_pulse_start + t_rise_fall:.6e} {target_voltage:.6e}"
    s += f" {t_pulse_start + t_pulse_width:.6e} {target_voltage:.6e}"
    s += f" {t_pulse_start + t_pulse_width + t_rise_fall:.6e} 0"
    # Ensure PWL definition extends to sim_stop
    if (t_pulse_start + t_pulse_width + t_rise_fall) < t_sim_stop:
         s += f" {t_sim_stop:.6e} 0"
    return s

# Wordline is common for enabling write, could be specific if more complex
common_wl_pwl = generate_voltage_pwl(VWL_H, pulse_start_time, PULSE_WIDTH_WRITE, rise_fall_time, TSTOP_WRITE)

# Generate PWL for each weight/DRAM cell
c1_bl_target_voltage = new_target_w1_voltage
c2_bl_target_voltage = new_target_w2_voltage

c1_bl_pwl = generate_voltage_pwl(c1_bl_target_voltage, pulse_start_time, PULSE_WIDTH_WRITE, rise_fall_time, TSTOP_WRITE)
c1_wl_pwl = common_wl_pwl

c2_bl_pwl = generate_voltage_pwl(c2_bl_target_voltage, pulse_start_time, PULSE_WIDTH_WRITE, rise_fall_time, TSTOP_WRITE)
c2_wl_pwl = common_wl_pwl

# Output PWL strings for Bash to source
with open("cell_PWL_strings.txt", "w") as f:
    f.write(f"CELL1_BL_PWL='{c1_bl_pwl}'\n")
    f.write(f"CELL1_WL_PWL='{c1_wl_pwl}'\n")
    f.write(f"CELL2_BL_PWL='{c2_bl_pwl}'\n")
    f.write(f"CELL2_WL_PWL='{c2_wl_pwl}'\n")

print("Python NN Controller: cell_PWL_strings.txt generated for SPICE.")
EOF

    echo "Bash: Running Python NN controller for Epoch $epoch..."
    python3 nn_controller.py \
        "$PY_VDD" \
        "$PY_VWL_H" \
        "$PY_TSTOP_WRITE_CYCLE" \
        "$PY_PULSE_WIDTH_WRITE" \
        "$LEARNING_RATE" \
        "$WEIGHTS_FILE" \
        "$PREVIOUS_SPICE_OUTPUT_CSV" \
        "$PERFORMANCE_LOG" \
        "$epoch"

    echo "Bash: Sourcing PWL strings for SPICE..."
    if [ -f cell_PWL_strings.txt ]; then
        source cell_PWL_strings.txt
    else
        echo "Bash: Error - cell_PWL_strings.txt not found! Python script might have failed."
        exit 1
    fi
    if [ -z "$CELL1_BL_PWL" ]; then
        echo "Bash: Error - PWL shell variables not set. Python script problem."
        exit 1
    fi
    echo "Bash: PWL strings sourced."

    # === Step 2: Write SPICE netlist for DRAM weight write ===
    cat > dram_nn_write.sp <<EOF
* DRAM Weight Write Simulation - Epoch $epoch
* Goal: Write target voltages (representing NN weights) to cell capacitors.

.PARAM sim_vdd = $PY_VDD
.PARAM sim_vwl_h = $PY_VWL_H
.PARAM sim_c_cell = $PY_C_CELL
.PARAM sim_r_cap_leak = $PY_R_CAP_LEAK
.PARAM sim_c_couple = $PY_C_COUPLE
.PARAM sim_r_couple_leak = $PY_R_COUPLE_LEAK
.PARAM sim_tran_tstep = 10n ; Fine enough for the write pulse

.model MyNMOS_Model NMOS (LEVEL=1 VTO=0.4 KP=100u W=0.2u L=0.1u) ; Slightly adjusted VTO

* --- Cell 1 (Weight W1) ---
Vwl1 c1_wl 0 PWL($CELL1_WL_PWL)
Vbl1 c1_bl 0 PWL($CELL1_BL_PWL)
Cc1  c1_node 0 {sim_c_cell}      ; Cell 1 Storage Capacitor (W1)
Rcl1 c1_node 0 {sim_r_cap_leak}  ; Cell 1 Leakage Resistor
M1   c1_bl c1_wl c1_node 0 MyNMOS_Model ; Access transistor for W1

* --- Cell 2 (Weight W2) ---
Vwl2 c2_wl 0 PWL($CELL2_WL_PWL)
Vbl2 c2_bl 0 PWL($CELL2_BL_PWL)
Cc2  c2_node 0 {sim_c_cell}      ; Cell 2 Storage Capacitor (W2)
Rcl2 c2_node 0 {sim_r_cap_leak}  ; Cell 2 Leakage Resistor
M2   c2_bl c2_wl c2_node 0 MyNMOS_Model ; Access transistor for W2

* --- Coupling (minimal for now) ---
Ccouple_cells c1_node c2_node {sim_c_couple}
Rcouple_cells c1_node c2_node {sim_r_couple_leak}

* --- Analysis ---
.tran {sim_tran_tstep} $PY_TSTOP_WRITE_CYCLE UIC

.control
set wr_vecnames              ; Ensure variable names are in first line
set wr_singlescale           ; Use time as the single scale
run
wrdata dram_sim_output.csv v(c1_node) v(c2_node) v(c1_wl) v(c1_bl) v(c2_wl) v(c2_bl)
* plot v(c1_node) v(c2_node) xlimit 0 $PY_TSTOP_WRITE_CYCLE ylimit -0.1 [ \$sim_vdd * 1.1 ]
listing e
quit
.endc

.end
EOF
    echo "Bash: dram_nn_write.sp netlist created for Epoch $epoch."

    # === Step 3: Run Ngspice ===
    echo "Bash: Running Ngspice for Epoch $epoch weight write..."
    NGSPICE_LOG="ngspice_run.log"
    ngspice -b dram_nn_write.sp -o "$NGSPICE_LOG" || {
        echo "Bash: Ngspice run FAILED for Epoch $epoch!"
        cat "$NGSPICE_LOG"
        exit 1
    }
    echo "Bash: Ngspice run completed for Epoch $epoch."
    if [ ! -s dram_sim_output.csv ]; then
        echo "Bash: Error - Ngspice output dram_sim_output.csv is missing or empty for Epoch $epoch."
        exit 1
    fi
    echo "Bash: dram_sim_output.csv created with resulting DRAM voltages."
    # This output will be read by the Python script in the NEXT epoch.

    cd .. # Back to SIM_DIR_BASE
done # End of Epoch loop

echo "Bash: ✅ All epochs completed."

# === Step 4: Python plot for overall training performance ===
cd "$SIM_DIR_BASE" # Ensure we are in the base directory for plotting
cat > plot_training_performance.py <<EOF
import matplotlib.pyplot as plt
import numpy as np
import sys

LOG_FILE = sys.argv[1]
VDD_PLOT = float(sys.argv[2])

try:
    data = np.genfromtxt(LOG_FILE, delimiter=',', names=True, skip_header=0)
except Exception as e:
    print(f"Plotting Error: Could not read {LOG_FILE}: {e}")
    sys.exit(1)

if len(data) == 0:
    print(f"Plotting Error: No data found in {LOG_FILE}.")
    sys.exit(1)

epochs = data['epoch']
w1_target = data['w1_target']
w2_target = data['w2_target']
bias = data['bias']
w1_actual = data['w1_actual_dram']
w2_actual = data['w2_actual_dram']
avg_error = data['avg_epoch_error']
accuracy = data['accuracy']

fig, axs = plt.subplots(3, 1, figsize=(12, 15), sharex=True)

# Plot 1: Weights
axs[0].plot(epochs, w1_target, label='W1 Target Voltage (to DRAM)', linestyle='-', marker='o', markersize=3)
axs[0].plot(epochs, w1_actual, label='W1 Actual Voltage (from DRAM)', linestyle='--', marker='x', markersize=3)
axs[0].plot(epochs, w2_target, label='W2 Target Voltage (to DRAM)', linestyle='-', marker='s', markersize=3)
axs[0].plot(epochs, w2_actual, label='W2 Actual Voltage (from DRAM)', linestyle='--', marker='p', markersize=3)
axs[0].plot(epochs, bias, label='Bias (Software)', linestyle=':', color='purple', marker='*', markersize=3)
axs[0].set_ylabel("Voltage (V) or Bias Value")
axs[0].set_title(f"NN Weights and Bias Evolution (Target vs. Actual DRAM) VDD={VDD_PLOT}V")
axs[0].legend(loc='best', fontsize='small')
axs[0].grid(True)
axs[0].axhline(0, color='black', linewidth=0.5) # y=0 line
axs[0].axhline(VDD_PLOT, color='grey', linestyle='--', linewidth=0.5, label=f'VDD={VDD_PLOT}V')


# Plot 2: Error
axs[1].plot(epochs, avg_error, label='Average Epoch Error', color='red', marker='.')
axs[1].set_ylabel("Average Error")
axs[1].set_title("Training Error Over Epochs")
axs[1].legend()
axs[1].grid(True)
axs[1].set_ylim(bottom=-0.05) # Error is non-negative

# Plot 3: Accuracy
axs[2].plot(epochs, accuracy, label='Accuracy', color='green', marker='.')
axs[2].set_ylabel("Accuracy")
axs[2].set_xlabel("Epoch")
axs[2].set_title("Training Accuracy Over Epochs")
axs[2].legend()
axs[2].grid(True)
axs[2].set_ylim(-0.05, 1.05)

plt.tight_layout()
plt.savefig("dram_nn_training_performance.png")
print(f"Python Plot: Training performance plot saved to dram_nn_training_performance.png")
# plt.show() # Uncomment to display plot if running interactively
EOF

echo "Bash: Plotting training performance..."
python3 plot_training_performance.py "$PERFORMANCE_LOG" "$PY_VDD"

echo "Bash: ✅✅ Overall simulation and plotting finished."
echo "Outputs are in $SIM_DIR_BASE. Key files:"
echo " - nn_performance_log.csv: Log of weights, errors, accuracy per epoch."
echo " - dram_nn_training_performance.png: Plot of the training process."
echo " - epoch_*/ : Subdirectories for each epoch's files (PWL, SPICE netlist, SPICE raw output)."
echo " - nn_weights.txt: Final target weights and bias."