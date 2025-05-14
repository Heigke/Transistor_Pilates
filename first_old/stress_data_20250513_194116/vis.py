#!/usr/bin/env python3
"""
NS-RAM System Stress Test Visualizer (Full Metric Coverage + Heatmaps)
"""

import os
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns

# === Utilities ===
def safe_float(df, cols):
    for col in cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors='coerce')
    return df

def load_data(data_dir):
    df_neuron = pd.read_csv(os.path.join(data_dir, "neuron_data.csv"))
    df_short = pd.read_csv(os.path.join(data_dir, "synaptic_short_data.csv"))
    df_long = pd.read_csv(os.path.join(data_dir, "synaptic_long_data.csv"))
    df_summary = pd.read_csv(os.path.join(data_dir, "system_summary.csv"))

    for df in [df_neuron, df_short, df_long]:
        df['datetime'] = pd.to_datetime(df['timestamp'], unit='s')

    metric_cols_neuron = ['temp', 'freq', 'recovery_time', 'ipc', 'l1d_misses_pmc',
                          'llc_misses_pmc', 'branch_misses_pmc', 'mbw_score_mbps',
                          'ecc_ce_count', 'ecc_ue_count']
    metric_cols_short = ['bench_score', 'percent_of_baseline', 'ipc', 'l1d_misses_pmc',
                         'llc_misses_pmc', 'branch_misses_pmc', 'mbw_score_mbps',
                         'ecc_ce_count', 'ecc_ue_count']
    metric_cols_long = ['temp', 'bench_score', 'ipc', 'l1d_misses_pmc', 'llc_misses_pmc',
                        'branch_misses_pmc', 'mbw_score_mbps', 'ecc_ce_count', 'ecc_ue_count']

    df_neuron = safe_float(df_neuron, metric_cols_neuron)
    df_neuron['freq'] = df_neuron['freq'] / 1000  # Convert to MHz
    df_short = safe_float(df_short, metric_cols_short)
    df_long = safe_float(df_long, metric_cols_long)

    df_summary['baseline'] = pd.to_numeric(df_summary['baseline'], errors='coerce')
    df_summary['final'] = pd.to_numeric(df_summary['final'], errors='coerce')
    df_summary['percent_change'] = pd.to_numeric(df_summary['percent_change'], errors='coerce')

    return df_neuron, df_short, df_long, df_summary

# === Plotting ===
def plot_summary(df_summary, output_dir):
    x = np.arange(len(df_summary))
    width = 0.35

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.bar(x - width/2, df_summary['baseline'], width, label='Baseline')
    ax.bar(x + width/2, df_summary['final'], width, label='Final')
    ax.set_xticks(x)
    ax.set_xticklabels(df_summary['metric'], rotation=45, ha='right')
    ax.set_title("System Summary: Baseline vs Final")
    ax.legend()
    plt.tight_layout()
    fig.savefig(os.path.join(output_dir, "summary_bar_plot.png"))
    plt.close(fig)

def plot_neuron(df_neuron, output_dir):
    fig, axs = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
    for cycle in df_neuron['cycle'].unique():
        subset = df_neuron[df_neuron['cycle'] == cycle]
        axs[0].plot(subset['datetime'], subset['temp'], label=f'Cycle {cycle}')
        axs[1].plot(subset['datetime'], subset['freq'], label=f'Cycle {cycle}')
    axs[0].set_title("Neuron Mode: Temperature")
    axs[1].set_title("Neuron Mode: Frequency (MHz)")
    for ax in axs:
        ax.legend()
        ax.grid(True)
    plt.tight_layout()
    fig.savefig(os.path.join(output_dir, "neuron_temp_freq.png"))
    plt.close(fig)

def plot_synaptic(df, label, output_file, output_dir):
    fig, ax = plt.subplots(figsize=(14, 6))
    for cycle in df['cycle'].unique():
        subset = df[df['cycle'] == cycle]
        ax.plot(subset['datetime'], subset['bench_score'], label=f'Cycle {cycle}')
    ax.set_title(f"{label}: Benchmark Score Over Time")
    ax.set_ylabel("Score")
    ax.legend()
    ax.grid(True)
    plt.tight_layout()
    fig.savefig(os.path.join(output_dir, output_file))
    plt.close(fig)

def percent_change_heatmap(df, metrics, title, output_path):
    df = df.copy()
    df = safe_float(df, metrics + ['cycle'])

    melted = df[metrics + ['cycle']].melt(id_vars='cycle', var_name='Metric', value_name='Value')
    grouped = melted.groupby(['Metric', 'cycle'])['Value'].mean().reset_index()
    pivoted = grouped.pivot(index='Metric', columns='cycle', values='Value')
    pct_change = pivoted.pct_change(axis=1).iloc[:, 1:] * 100

    fig, ax = plt.subplots(figsize=(12, 6))
    sns.heatmap(pct_change, annot=True, fmt=".2f", cmap='coolwarm', center=0, ax=ax)
    ax.set_title(f"Percentage Change in Metrics by Cycle - {title}")
    plt.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)

# === Main ===
def main():
    import argparse
    parser = argparse.ArgumentParser(description="Visualize NS-RAM Stress Test Results")
    parser.add_argument("data_dir", help="Directory containing NS-RAM CSV output")
    parser.add_argument("-o", "--output_dir", default=None, help="Output directory for plots")
    args = parser.parse_args()

    data_dir = args.data_dir
    output_dir = args.output_dir or data_dir
    os.makedirs(output_dir, exist_ok=True)

    print("[*] Loading data...")
    df_neuron, df_short, df_long, df_summary = load_data(data_dir)

    print("[*] Generating plots...")
    plot_summary(df_summary, output_dir)
    plot_neuron(df_neuron, output_dir)
    plot_synaptic(df_short, "Synaptic Short-Term", "synaptic_short_term_bench.png", output_dir)
    plot_synaptic(df_long, "Synaptic Long-Term", "synaptic_long_term_bench.png", output_dir)

    metrics_to_plot = ['bench_score', 'l1d_misses_pmc', 'llc_misses_pmc',
                       'branch_misses_pmc', 'mbw_score_mbps']

    print("[*] Generating heatmaps...")
    percent_change_heatmap(df_short, metrics_to_plot,
                           title="Synaptic Short-Term",
                           output_path=os.path.join(output_dir, "pct_change_synaptic_short.png"))
    percent_change_heatmap(df_long, metrics_to_plot,
                           title="Synaptic Long-Term",
                           output_path=os.path.join(output_dir, "pct_change_synaptic_long.png"))

    print(f"[✓] All plots saved to: {output_dir}")

if __name__ == "__main__":
    main()
