#!/usr/bin/env python3
"""
NS-RAM Synaptic Short-Term Analysis: Full Metrics with Seaborn % Change Heatmaps
"""

import os
import pandas as pd
import numpy as np
import seaborn as sns
import matplotlib.pyplot as plt

# === Utilities ===
def safe_float(df, cols):
    for col in cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors='coerce')
    return df

def load_short_term_data(data_dir):
    df = pd.read_csv(os.path.join(data_dir, "synaptic_short_data.csv"))
    df['datetime'] = pd.to_datetime(df['timestamp'], unit='s')

    metric_cols = ['bench_score', 'percent_of_baseline', 'ipc', 'l1d_misses_pmc',
                   'llc_misses_pmc', 'branch_misses_pmc', 'mbw_score_mbps',
                   'ecc_ce_count', 'ecc_ue_count']

    df = safe_float(df, metric_cols)
    return df, metric_cols

def percent_change_heatmap_by_time(df, metrics, output_file, title):
    """
    Plot a seaborn heatmap showing percentage change of each metric over time (timestamp-level granularity)
    with annotated x-axis labels.
    """
    df = df.copy()
    df = df.sort_values(by="timestamp")  # Ensure chronological order
    df = safe_float(df, metrics)

    # Create descriptive x-axis labels
    df["label"] = df.apply(lambda row: f"{row['timestamp']} | C{row['cycle']} | {row['phase']} | P{row['pulse_or_elapsed']}", axis=1)

    # Metric dataframe: metrics as rows, timestamps as columns
    metric_df = df[metrics].transpose()

    # Percent change across time steps
    pct_change = metric_df.pct_change(axis=1) * 100
    pct_change = pct_change.iloc[:, 1:]  # Remove first column (no baseline for pct change)

    # Set x-axis labels using the descriptive labels (excluding baseline step)
    time_labels = df['label'].iloc[1:].values
    pct_change.columns = time_labels

    # Plot heatmap
    fig, ax = plt.subplots(figsize=(16, 10))
    sns.heatmap(pct_change, annot=False, fmt=".2f", cmap="coolwarm", center=0, linewidths=0.5, ax=ax)

    ax.set_title(f"{title} - % Change Over Time Steps")
    ax.set_xlabel("Timestamp | Cycle | Phase | Pulse")
    ax.set_ylabel("Metric")
    ax.set_xticklabels(ax.get_xticklabels(), rotation=45, ha='right')
    plt.tight_layout()
    fig.savefig(output_file)
    plt.close(fig)



# === Main ===
def main():
    import argparse
    parser = argparse.ArgumentParser(description="NS-RAM Synaptic Short-Term Metric Change Heatmap")
    parser.add_argument("data_dir", help="Path to directory containing synaptic_short_data.csv")
    parser.add_argument("-o", "--output_dir", default=None, help="Directory to save heatmaps")
    args = parser.parse_args()

    data_dir = args.data_dir
    output_dir = args.output_dir or data_dir
    os.makedirs(output_dir, exist_ok=True)

    print("[*] Loading synaptic short-term data...")
    df_short, metrics = load_short_term_data(data_dir)

    print("[*] Generating Seaborn % change heatmap by timestamp...")
    percent_change_heatmap_by_time(df_short, metrics,
                                   output_file=os.path.join(output_dir, "synaptic_short_heatmap_timestamp.png"),
                                   title="Synaptic Short-Term")


    print("[✓] Saved heatmap to:", output_dir)

if __name__ == "__main__":
    main()
