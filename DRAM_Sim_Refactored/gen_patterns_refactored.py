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
