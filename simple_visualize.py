import os
import glob
import argparse
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

# --- Configuration for Plot Aesthetics ---
PLOT_STYLE = 'seaborn-v0_8-whitegrid'
FIG_SIZE = (14, 7)
TEMP_COLOR = 'crimson'
FREQ_COLOR = 'royalblue'
FONT_SIZE_TITLE = 16
FONT_SIZE_LABEL = 12
FONT_SIZE_TICKS = 10
LINE_WIDTH = 1.5
MARKER_STYLE = 'o'
MARKER_SIZE = 3
MARKER_EDGE_COLOR = 'black'
MARKER_EDGE_WIDTH = 0.5

# --- Helper Functions ---

def find_data_directories(base_path="."):
    """
    Finds relevant data directories based on common prefixes.
    """
    patterns = [
        os.path.join(base_path, "simplified_stress_data_*"),
        os.path.join(base_path, "hammer_test_*"),
        os.path.join(base_path, "spec_havoc_test_*"),
    ]
    data_dirs = []
    for pattern in patterns:
        data_dirs.extend(glob.glob(pattern))
    
    # Filter out any non-directory results, just in case
    data_dirs = [d for d in data_dirs if os.path.isdir(d)]
    
    if not data_dirs:
        print(f"No data directories found in '{os.path.abspath(base_path)}' with known prefixes.")
        print("Expected prefixes: 'simplified_stress_data_*', 'hammer_test_*', 'spec_havoc_test_*'")
    return data_dirs

def load_csv_data(csv_path):
    """
    Loads data from a CSV file into a pandas DataFrame.
    Performs basic cleaning and type conversion.
    """
    if not os.path.exists(csv_path) or os.path.getsize(csv_path) == 0:
        print(f"Warning: CSV file '{csv_path}' not found or is empty. Skipping.")
        return None
    try:
        df = pd.read_csv(csv_path)
        
        # Convert timestamp to datetime objects if 'timestamp_utc' exists
        if 'timestamp_utc' in df.columns:
            df['timestamp'] = pd.to_datetime(df['timestamp_utc'], errors='coerce')
        elif 'timestamp_epoch_s' in df.columns: # Fallback to epoch seconds
            df['timestamp_epoch_s'] = pd.to_numeric(df['timestamp_epoch_s'], errors='coerce')
            df['timestamp'] = pd.to_datetime(df['timestamp_epoch_s'], unit='s', errors='coerce')
        else:
            print(f"Warning: No recognized timestamp column in '{csv_path}'. Plotting against index.")
            df['timestamp'] = df.index

        df.dropna(subset=['timestamp'], inplace=True) # Drop rows where timestamp conversion failed

        # Convert metrics to numeric, coercing errors to NaN
        for col in ['temp_c', 'freq_khz']:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors='coerce')
        
        # Handle hammer_exit_code specifically
        if 'hammer_exit_code' in df.columns:
            # Ensure it's treated as object/string initially, then try numeric for comparison
            df['hammer_exit_code_str'] = df['hammer_exit_code'].astype(str)


        # Sort by timestamp just in case
        df.sort_values(by='timestamp', inplace=True)
        
        return df
    except Exception as e:
        print(f"Error loading or processing CSV file '{csv_path}': {e}")
        return None

def setup_plot_style():
    """Applies a consistent style to plots."""
    try:
        plt.style.use(PLOT_STYLE)
    except:
        print(f"Warning: Plot style '{PLOT_STYLE}' not available. Using default.")
    plt.rcParams['figure.figsize'] = FIG_SIZE
    plt.rcParams['font.size'] = FONT_SIZE_LABEL
    plt.rcParams['axes.titlesize'] = FONT_SIZE_TITLE
    plt.rcParams['xtick.labelsize'] = FONT_SIZE_TICKS
    plt.rcParams['ytick.labelsize'] = FONT_SIZE_TICKS

# --- Plotting Functions ---

def plot_dual_axis_timeseries(df, output_path, title_prefix,
                              y1_col='temp_c', y1_label='Temperature (°C)', y1_color=TEMP_COLOR,
                              y2_col='freq_khz', y2_label='Frequency (KHz)', y2_color=FREQ_COLOR,
                              phase_col='phase', extra_title_info=""):
    """
    Generates a dual-axis plot for temperature and frequency over time.
    Highlights phases if the 'phase' column is available.
    """
    if df is None or df.empty:
        print(f"No data to plot for {title_prefix}.")
        return

    fig, ax1 = plt.subplots()

    # Determine X-axis: if 'timestamp' is datetime, use it, otherwise use index.
    if pd.api.types.is_datetime64_any_dtype(df['timestamp']):
        time_data = df['timestamp']
        ax1.set_xlabel("Time (UTC)")
        ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
        fig.autofmt_xdate()
    else: # Fallback for non-datetime timestamps (e.g. just seconds from start or index)
        if 'timestamp_epoch_s' in df.columns: # Use seconds from start if available
             time_data = df['timestamp_epoch_s'] - df['timestamp_epoch_s'].iloc[0]
             ax1.set_xlabel("Time (seconds from start)")
        else: # Use index if nothing else
            time_data = df.index
            ax1.set_xlabel("Sample Index")


    # Plot Temperature (Y1)
    if y1_col in df.columns and not df[y1_col].isnull().all():
        ax1.plot(time_data, df[y1_col], color=y1_color, linewidth=LINE_WIDTH,
                 marker=MARKER_STYLE, markersize=MARKER_SIZE, 
                 markeredgecolor=MARKER_EDGE_COLOR, markeredgewidth=MARKER_EDGE_WIDTH,
                 label=y1_label)
        ax1.set_ylabel(y1_label, color=y1_color)
        ax1.tick_params(axis='y', labelcolor=y1_color)
    else:
        print(f"Warning: Column '{y1_col}' not found or all NaN in data for '{title_prefix}'. Skipping Y1 plot.")

    # Create second Y-axis for Frequency
    ax2 = ax1.twinx()
    if y2_col in df.columns and not df[y2_col].isnull().all():
        ax2.plot(time_data, df[y2_col], color=y2_color, linewidth=LINE_WIDTH,
                 marker=MARKER_STYLE, markersize=MARKER_SIZE, linestyle='--',
                 markeredgecolor=MARKER_EDGE_COLOR, markeredgewidth=MARKER_EDGE_WIDTH,
                 label=y2_label)
        ax2.set_ylabel(y2_label, color=y2_color)
        ax2.tick_params(axis='y', labelcolor=y2_color)
    else:
        print(f"Warning: Column '{y2_col}' not found or all NaN in data for '{title_prefix}'. Skipping Y2 plot.")

    # Add vertical lines and shaded regions for phases if 'phase' column exists
    if phase_col in df.columns and pd.api.types.is_datetime64_any_dtype(df['timestamp']):
        current_phase = None
        phase_start_time = None
        unique_phases = df[phase_col].dropna().unique()
        
        # Check if plt.cm.get_cmap is deprecated, use plt.colormaps.get if so
        try:
            phase_colors = plt.colormaps.get('Pastel1')
            color_map = {phase: phase_colors(i % phase_colors.N) for i, phase in enumerate(unique_phases)}
        except AttributeError: # Fallback for older matplotlib
             phase_colors_cmap = plt.cm.get_cmap('Pastel1', len(unique_phases))
             color_map = {phase: phase_colors_cmap(i) for i, phase in enumerate(unique_phases)}


        for i, row in df.iterrows():
            if current_phase is None: # First data point
                current_phase = row[phase_col]
                phase_start_time = row['timestamp']
            elif row[phase_col] != current_phase:
                if phase_start_time and current_phase: # End of a phase
                    ax1.axvspan(phase_start_time, row['timestamp'], 
                                color=color_map.get(current_phase, 'gray'), alpha=0.2,
                                label=f'{current_phase} phase' if current_phase not in [h.get_label() for h in ax1.get_legend_handles_labels()[0]] else "")
                current_phase = row[phase_col]
                phase_start_time = row['timestamp']
        
        if phase_start_time and current_phase: # Last phase
            ax1.axvspan(phase_start_time, df['timestamp'].iloc[-1], 
                        color=color_map.get(current_phase, 'gray'), alpha=0.2,
                        label=f'{current_phase} phase' if current_phase not in [h.get_label() for h in ax1.get_legend_handles_labels()[0]] else "")

    # Add title and legend
    plt.title(f"{title_prefix}: Temperature & Frequency Over Time\n{extra_title_info}".strip(), fontsize=FONT_SIZE_TITLE)
    
    # Combine legends from both axes if they exist
    lines, labels = [], []
    if ax1.get_legend_handles_labels()[0]:
        lines_ax1, labels_ax1 = ax1.get_legend_handles_labels()
        lines.extend(lines_ax1)
        labels.extend(labels_ax1)
    if ax2.get_legend_handles_labels()[0]:
        lines_ax2, labels_ax2 = ax2.get_legend_handles_labels()
        lines.extend(lines_ax2)
        labels.extend(labels_ax2)
    
    if lines: # Only show legend if there's something to show
        fig.legend(lines, labels, loc='upper right', bbox_to_anchor=(0.9, 0.9),
                   bbox_transform=ax1.transAxes, frameon=True, shadow=True)

    plt.tight_layout(rect=[0, 0, 1, 0.96]) # Adjust layout to make space for suptitle and legend
    
    try:
        plt.savefig(output_path, bbox_inches='tight', dpi=150)
        print(f"Plot saved to: {output_path}")
    except Exception as e:
        print(f"Error saving plot '{output_path}': {e}")
    plt.close(fig)


# --- Interpretation Text Functions ---

def interpret_lif_analogy(data_dir, plot_path):
    print("\n--- Interpretation for LIF Analogy Test ---")
    print(f"Data Directory: {data_dir}")
    print(f"Plot: {plot_path}")
    print("This test simulates the Leaky Integrate & Fire (LIF) neuron model at a system level.")
    print("Look for these patterns in the plot:")
    print("  - 'Integrate' Phase (Stress):")
    print("    - Temperature should rise significantly.")
    print("    - CPU Frequency might initially be high, then drop if thermal throttling occurs.")
    print("      This drop can be considered an analogous 'firing threshold' being approached or met.")
    print("  - 'Fire' Event (Analogy):")
    print("    - The peak temperature reached or a significant, sustained frequency drop during stress.")
    print("      This is the system's response to overwhelming load, similar to a neuron firing.")
    print("  - 'Leak/Recover' Phase (Recovery):")
    print("    - Temperature should gradually decrease towards baseline.")
    print("    - CPU Frequency should recover to its baseline or a stable idle state.")
    print("    - The rate of recovery indicates the system's 'leakiness' or resilience.")
    print("Consider:")
    print("  - How high does the temperature get? How low does the frequency drop?")
    print("  - How quickly does the system recover after stress is removed?")
    print("  - Are there plateaus in temperature or frequency, indicating sustained throttling?")
    print("-" * 50)

def interpret_hammer_test(data_dir, plot_path, df):
    print("\n--- Interpretation for Hammer Memory Stress Test ---")
    print(f"Data Directory: {data_dir}")
    print(f"Plot: {plot_path}")
    print("This test runs a 'Rowhammer-like' tool to stress memory intensely.")
    print("The analogy is applying a strong, localized stimulus that might cause a state change (bit flip).")
    print("Look for these patterns in the plot and data:")
    print("  - System Response During Hammering:")
    print("    - Temperature might increase due to overall system activity (CPU managing memory, memory controller work).")
    print("    - CPU Frequency changes might be less directly correlated unless the CPU itself is also heavily loaded by the test setup.")
    print("  - Hammer Exit Code (Key Indicator - check CSV/log for 'hammer_exit_code'):")
    
    corruption_detected_text = "No specific corruption info processed from CSV for this interpretation."
    if df is not None and 'hammer_exit_code_str' in df.columns:
        last_exit_code = df['hammer_exit_code_str'].dropna().iloc[-1] if not df['hammer_exit_code_str'].dropna().empty else "N/A"
        if last_exit_code == "2": # Based on the C code's exit status for corruption
            corruption_detected_text = "!!! HAMMER DETECTED BIT FLIP (Corruption Likely) - Exit Code 2 !!!"
        elif last_exit_code == "0":
            corruption_detected_text = "Hammer reported no bit flips - Exit Code 0."
        elif last_exit_code != "N/A":
            corruption_detected_text = f"Hammer finished with exit code {last_exit_code} (check tool's meaning)."
        else:
             corruption_detected_text = "Hammer exit code not available or N/A in the last relevant CSV row."
    
    print(f"    * {corruption_detected_text}")
    print("      - If corruption is detected (e.g., exit code 2 from the provided C code), this is a major 'event' or 'fault state,'")
    print("        analogous to a memory cell's state being irreversibly altered by stress beyond its threshold.")
    print("Consider:")
    print("  - Did the system remain stable during the hammer test, or did it crash/hang (requiring manual check)?")
    print("  - The primary outcome is often the hammer tool's own report of bit flips, rather than just temp/freq.")
    print("-" * 50)

def interpret_spec_havoc_test(data_dir, plot_path):
    print("\n--- Interpretation for Speculative Execution Havoc CPU Stress Test ---")
    print(f"Data Directory: {data_dir}")
    print(f"Plot: {plot_path}")
    print("This test runs a CPU-intensive program using specific assembly instructions that can heavily load execution units.")
    print("The analogy is an intense, targeted stimulus to the CPU cores.")
    print("Look for these patterns in the plot:")
    print("  - System Response During Havoc Stress:")
    print("    - Temperature should rise significantly due to high CPU load.")
    print("    - CPU Frequency will likely drop if thermal or power limits are reached (throttling).")
    print("      This is a direct measure of the CPU's response to extreme computational demand.")
    print("  - Recovery Post-Havoc:")
    print("    - Similar to the LIF analogy, observe temperature and frequency returning to baseline.")
    print("Consider:")
    print("  - How does this CPU-specific stress compare to the more general `stress-ng` CPU load in the LIF test?")
    print("    Is the temperature peak higher? Does frequency drop more severely?")
    print("  - This test primarily shows the system's thermal and power management response to a specific type of CPU workload.")
    print("-" * 50)


# --- Main Execution ---

def main():
    parser = argparse.ArgumentParser(
        description="Plot and interpret data from NS-RAM System-Level Analogy tests."
    )
    parser.add_argument(
        "base_directory",
        nargs="?",
        default=".",
        help="The base directory containing the test data subdirectories (e.g., 'simplified_stress_data_*'). Defaults to current directory."
    )
    args = parser.parse_args()

    setup_plot_style()
    data_dirs = find_data_directories(args.base_directory)

    if not data_dirs:
        return

    print(f"Found {len(data_dirs)} data directories. Processing...\n")

    for data_dir in sorted(data_dirs):
        dir_name = os.path.basename(data_dir)
        print(f"Processing directory: {data_dir}")
        
        df = None
        plot_file_name = f"{dir_name}_plot.png"
        plot_path = os.path.join(data_dir, plot_file_name)
        extra_info_for_title = ""

        if dir_name.startswith("simplified_stress_data"):
            csv_path = os.path.join(data_dir, "neuron_lif_analogy_data.csv")
            df = load_csv_data(csv_path)
            if df is not None:
                plot_dual_axis_timeseries(df, plot_path, "LIF Analogy Test", phase_col='phase')
                interpret_lif_analogy(data_dir, plot_path)
        
        elif dir_name.startswith("hammer_test"):
            csv_path = os.path.join(data_dir, "hammer_telemetry_data.csv")
            df = load_csv_data(csv_path)
            if df is not None:
                if 'hammer_exit_code_str' in df.columns:
                    last_exit_code = df['hammer_exit_code_str'].dropna().iloc[-1] if not df['hammer_exit_code_str'].dropna().empty else "N/A"
                    if last_exit_code == "2":
                        extra_info_for_title = "Hammer Corruption Detected (Exit Code 2)!"
                    elif last_exit_code != "N/A" and last_exit_code != "0":
                         extra_info_for_title = f"Hammer Exit Code: {last_exit_code}"
                plot_dual_axis_timeseries(df, plot_path, "Hammer Memory Stress Test", phase_col='phase', extra_title_info=extra_info_for_title) # phase can be baseline, hammer_active, post_hammer
                interpret_hammer_test(data_dir, plot_path, df)

        elif dir_name.startswith("spec_havoc_test"):
            csv_path = os.path.join(data_dir, "spec_havoc_telemetry_data.csv")
            df = load_csv_data(csv_path)
            if df is not None:
                plot_dual_axis_timeseries(df, plot_path, "Speculative Execution Havoc CPU Test", phase_col='phase') # phase can be baseline, havoc_stress, post_havoc
                interpret_spec_havoc_test(data_dir, plot_path)
        else:
            print(f"Skipping unknown directory type: {data_dir}")
        
        print("-" * 60)

    print("\nAll processing finished.")
    print("Check the respective data directories for generated plots (e.g., *_plot.png).")

if __name__ == "__main__":
    main()