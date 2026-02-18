#!/usr/bin/env python3
"""
Discover input sizes (IS1, IS2, ...), run types (baseline, optimized, etc.) from a
routine tasks folder and plot runtimes as grouped boxplots.
Expects: tasks_folder/IS1/run_type/runN/runtimes
Stores the plot(s) as PDF (runtimes1.pdf, runtimes2.pdf, etc.).
"""
import argparse
import re
from pathlib import Path
from typing import Dict, List, Tuple


import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

# Units for runtime display: (scale factor from ns, label)
RUNTIME_UNITS = [
    (1e9, "s"),
    (1e6, "ms"),
    (1e3, "us"),
    (1.0, "ns"),
]


def discover_experiment_data(
    tasks_folder: Path,
) -> Tuple[List[str], List[str], Dict[Tuple[str, str], List[float]]]:
    """
    Discover input sizes, run types, and collect runtimes from a routine tasks folder.
    tasks_folder = e.g. tasks/experiment/MatMul with structure:
      tasks_folder/IS1/run_type/runN/runtimes
    Returns (input_sizes, run_types, data) where data[(is_name, run_type)] = list of runtimes in ns.
    """
    if not tasks_folder.is_dir():
        raise ValueError(f"Tasks folder does not exist or is not a directory: {tasks_folder}")

    # Input sizes: IS1, IS2, ... (sorted)
    input_sizes = sorted(
        d.name
        for d in tasks_folder.iterdir()
        if d.is_dir() and re.match(r"^IS\d+$", d.name)
    )

    # Run types: baseline, optimized, reference, etc. (from first input size)
    # Exclude "data" which does not produce runtimes
    run_types = []
    if input_sizes:
        first_is_path = tasks_folder / input_sizes[0]
        run_types = sorted(
            d.name
            for d in first_is_path.iterdir()
            if d.is_dir() and not d.name.startswith(".") and d.name != "data"
        )

    # Collect runtimes: data[(is_name, run_type)] = list of all runtimes (ns)
    data: Dict[Tuple[str, str], List[float]] = {}
    for is_name in input_sizes:
        is_path = tasks_folder / is_name
        for run_type in run_types:
            run_type_path = is_path / run_type
            if not run_type_path.is_dir():
                continue
            runtimes_ns: list[float] = []
            for run_dir in sorted(run_type_path.iterdir()):
                if not run_dir.is_dir() or not re.match(r"^run\d+$", run_dir.name):
                    continue
                runtimes_file = run_dir / "runtimes"
                if runtimes_file.is_file():
                    with open(runtimes_file) as f:
                        for line in f:
                            line = line.strip()
                            if line:
                                try:
                                    runtimes_ns.append(float(line))
                                except ValueError:
                                    pass
            if runtimes_ns:
                data[(is_name, run_type)] = runtimes_ns

    return input_sizes, run_types, data


def group_input_sizes_by_magnitude(
    input_sizes: List[str],
    data: Dict[Tuple[str, str], List[float]],
) -> List[List[str]]:
    """
    Group input sizes by floor(log10(median_runtime)).
    Returns list of groups, each group a list of input size names, sorted by ascending order of magnitude.
    """
    om_to_sizes: Dict[int, List[str]] = {}
    for is_name in input_sizes:
        all_runtimes: List[float] = []
        for key, vals in data.items():
            if key[0] == is_name:
                all_runtimes.extend(vals)
        if not all_runtimes:
            continue
        median_val = float(np.median(all_runtimes))
        median_val = max(1.0, median_val)
        om = int(np.floor(np.log10(median_val)))
        if om not in om_to_sizes:
            om_to_sizes[om] = []
        om_to_sizes[om].append(is_name)
    for sizes in om_to_sizes.values():
        sizes.sort(key=lambda s: input_sizes.index(s))
    return [om_to_sizes[om] for om in sorted(om_to_sizes)]


def plot_grouped_boxplots(
    input_sizes: List[str],
    run_types: List[str],
    data: Dict[Tuple[str, str], List[float]],
    output_path: Path,
) -> None:
    """Create grouped boxplots and save as PDF."""
    n_input_sizes = len(input_sizes)
    n_run_types = len(run_types)
    if n_input_sizes == 0 or n_run_types == 0:
        raise ValueError("No input sizes or run types found")

    # Build plot data: for each (input_size, run_type) a box
    box_data: list[list[float]] = []
    labels: list[str] = []
    positions: list[float] = []
    group_gap = 0.5
    box_width = 0.6

    pos = 0
    for is_name in input_sizes:
        for run_type in run_types:
            key = (is_name, run_type)
            if key in data and data[key]:
                positions.append(pos)
                box_data.append(data[key])
                labels.append(run_type)
                pos += 1
        pos += group_gap

    if not box_data:
        raise ValueError("No runtime data found")

    # Choose unit so typical values have few digits (aim for 1–1000 range)
    all_vals = [v for vals in box_data for v in vals]
    median_ns = float(np.median(all_vals))
    scale, unit = 1.0, "ns"
    for s, u in RUNTIME_UNITS:
        if median_ns >= s:
            scale, unit = s, u
            break
    scaled_data = [[v / scale for v in vals] for vals in box_data]

    fig, ax = plt.subplots(figsize=(8, 5))
    bp = ax.boxplot(
        scaled_data,
        positions=positions,
        widths=box_width,
        patch_artist=True,
        showfliers=True,
    )

    # Color by run type
    cmap = plt.get_cmap("Set2")
    colors = cmap(np.linspace(0, 1, n_run_types))
    run_type_to_color = {rt: colors[i] for i, rt in enumerate(run_types)}
    for patch, label in zip(bp["boxes"], labels):
        patch.set_facecolor(run_type_to_color.get(label, "lightgray"))

    # X-axis: tick at center of each input size group
    tick_positions = []
    tick_labels = []
    pos = 0
    for is_name in input_sizes:
        group_count = sum(
            1 for rt in run_types if (is_name, rt) in data and data[(is_name, rt)]
        )
        if group_count > 0:
            center = pos + (group_count - 1) / 2
            tick_positions.append(center)
            tick_labels.append(is_name)
            pos += group_count + group_gap
        else:
            pos += group_gap


    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels)
    ax.set_xlabel("Input size")
    ax.set_ylabel(f"Runtime ({unit})")
    sf = ticker.ScalarFormatter(useOffset=False)
    sf.set_scientific(False)
    ax.yaxis.set_major_formatter(sf)
    ax.set_title("Runtimes by input size and run type")

    from matplotlib.patches import Patch

    legend_elements = [
        Patch(facecolor=run_type_to_color[rt], label=rt) for rt in run_types
    ]
    ax.legend(handles=legend_elements, loc="upper right")

    plt.tight_layout()
    fig.savefig(output_path, format="pdf", bbox_inches="tight")
    plt.close()
    print(f"Saved plot to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot runtimes from a routine tasks folder (e.g. tasks/experiment/MatMul)"
    )
    parser.add_argument(
        "tasks_folder",
        type=Path,
        help="Path to tasks folder with input sizes (IS1, IS2, ...) and run types as subfolders",
    )
    args = parser.parse_args()

    tasks_folder = args.tasks_folder.resolve()

    input_sizes, run_types, data = discover_experiment_data(tasks_folder)
    print(f"Discovered input sizes: {input_sizes}")
    print(f"Discovered run types: {run_types}")
    for key, vals in sorted(data.items()):
        print(f"  {key}: {len(vals)} runtimes")

    groups = group_input_sizes_by_magnitude(input_sizes, data)
    for i, group in enumerate(groups, start=1):
        group_data = {
            k: v for k, v in data.items()
            if k[0] in group
        }
        output_path = Path.cwd() / f"runtimes{i}.pdf"
        plot_grouped_boxplots(group, run_types, group_data, output_path)


if __name__ == "__main__":
    main()
