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
