import numpy as np

np.random.seed(42)

num_switches = 6
TSTOP = 20e-6
VDD = 1.2
VWL_H = 2.0
pulse_width = 0.5e-6

# --- Cell 1 Time Generation (remains the same) ---
cell1_times_raw = np.sort(np.random.uniform(0.5e-6, TSTOP - (pulse_width + 1.1e-6), num_switches))
cell1_times = np.copy(cell1_times_raw)
minimum_interval_between_starts = pulse_width + 1e-9 + 1e-10
if num_switches > 1:
    for i in range(1, num_switches):
        required_next_start_time = cell1_times[i-1] + minimum_interval_between_starts
        if cell1_times[i] < required_next_start_time:
            cell1_times[i] = required_next_start_time
if num_switches > 0 and (cell1_times[-1] + pulse_width + 1e-9 >= TSTOP):
    print(f"Error: Cell 1 last pulse ends too late. Exiting.")
    exit(1)

# --- Cell 2 Time Generation (remains the same, derived from Cell 1) ---
cell2_times = cell1_times + 0.25e-6 # Standard offset
if num_switches > 0 and (cell2_times[-1] + pulse_width + 1e-9 >= TSTOP):
    print(f"Error: Cell 2 last pulse (derived) ends too late. Exiting.")
    exit(1)

# --- Cell 1 Pattern Generation (remains the same) ---
cell1_pattern = np.random.randint(0, 2, size=num_switches)

# --- PWL Function (remains the same) ---
def pattern_to_pwl(times, values, high_voltage, p_width, sim_tstop):
    s = "0 0"
    final_voltage_at_tstop = 0
    if not times.size:
        s += f" {sim_tstop:.6e} {final_voltage_at_tstop}"
        return s
    for t, v_pattern in zip(times, values):
        actual_voltage = high_voltage if v_pattern else 0
        s += f" {t:.6e} {actual_voltage}"
        s += f" {t + p_width:.6e} {actual_voltage}"
        s += f" {t + p_width + 1e-9:.6e} 0"
    last_time_point_from_pulses = times[-1] + p_width + 1e-9
    if last_time_point_from_pulses < sim_tstop:
         s += f" {sim_tstop:.6e} {final_voltage_at_tstop}"
    return s

# --- Generate Cell 1 PWL (remains the same) ---
cell1_bl_pwl = pattern_to_pwl(cell1_times, cell1_pattern, VDD, pulse_width, TSTOP)
cell1_wl_pwl = pattern_to_pwl(cell1_times, np.ones(num_switches, dtype=int), VWL_H, pulse_width, TSTOP)

# === DEBUGGING CELL 2: Force a single '1' write ===
print("DEBUG: Forcing Cell 2 to a single '1' write at a fixed time.")
debug_cell2_t_start = 7e-6  # e.g., 7us, ensure this is within TSTOP and after any initial events
debug_cell2_bl_val_to_write = VDD # Target VDD on bitline
debug_cell2_wl_val_to_activate = VWL_H # Activate wordline

if debug_cell2_t_start + pulse_width + 1e-9 < TSTOP:
    # Cell 2 Bitline: pulse to VDD
    cell2_bl_pwl_debug_str = f"0 0 "
    cell2_bl_pwl_debug_str += f"{debug_cell2_t_start:.6e} {debug_cell2_bl_val_to_write} "
    cell2_bl_pwl_debug_str += f"{debug_cell2_t_start + pulse_width:.6e} {debug_cell2_bl_val_to_write} "
    cell2_bl_pwl_debug_str += f"{debug_cell2_t_start + pulse_width + 1e-9:.6e} 0 "
    cell2_bl_pwl_debug_str += f"{TSTOP:.6e} 0"
    
    # Cell 2 Wordline: pulse to VWL_H
    cell2_wl_pwl_debug_str = f"0 0 "
    cell2_wl_pwl_debug_str += f"{debug_cell2_t_start:.6e} {debug_cell2_wl_val_to_activate} "
    cell2_wl_pwl_debug_str += f"{debug_cell2_t_start + pulse_width:.6e} {debug_cell2_wl_val_to_activate} "
    cell2_wl_pwl_debug_str += f"{debug_cell2_t_start + pulse_width + 1e-9:.6e} 0 "
    cell2_wl_pwl_debug_str += f"{TSTOP:.6e} 0"
    
    final_cell2_bl_pwl = cell2_bl_pwl_debug_str
    final_cell2_wl_pwl = cell2_wl_pwl_debug_str
    print(f"DEBUG: Cell 2 BL PWL (Forced): {final_cell2_bl_pwl}")
    print(f"DEBUG: Cell 2 WL PWL (Forced): {final_cell2_wl_pwl}")
else:
    print("DEBUG: Fixed pulse time for Cell 2 is too late for TSTOP. Using original random generation (which might be problematic).")
    # Fallback to original random generation if the fixed pulse is too late (should not happen with chosen time)
    # This part would ideally re-enable the original cell2 pattern generation if needed
    # For this test, if the fixed pulse is "too late", it indicates a problem with the debug values or TSTOP.
    # We will assume the fixed pulse time is fine. If not, the script will use whatever was in these variables.
    original_cell2_pattern = np.random.randint(0, 2, size=num_switches) # Re-generate if needed
    final_cell2_bl_pwl = pattern_to_pwl(cell2_times, original_cell2_pattern, VDD, pulse_width, TSTOP)
    final_cell2_wl_pwl = pattern_to_pwl(cell2_times, np.ones(num_switches, dtype=int), VWL_H, pulse_width, TSTOP)


# --- Write to file ---
with open("cell_patterns.txt", "w") as f:
    f.write(f"CELL1_BL_PWL='{cell1_bl_pwl}'\n")
    f.write(f"CELL2_BL_PWL='{final_cell2_bl_pwl}'\n") # Use the potentially forced debug PWL
    f.write(f"CELL1_WL_PWL='{cell1_wl_pwl}'\n")
    f.write(f"CELL2_WL_PWL='{final_cell2_wl_pwl}'\n") # Use the potentially forced debug PWL
    f.write(f"PY_VDD='{VDD}'\n")
    f.write(f"PY_VWL_H='{VWL_H}'\n")
    f.write(f"PY_TSTOP='{TSTOP}'\n")

print("Generated cell_patterns.txt (Cell 2 may have forced fixed PWL for debugging)")
