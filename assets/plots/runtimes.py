#!/usr/bin/env python3
"""
Plot speedup of competitors over baseline from experiment results.

Expected input structure:
  <experiment_dir>/<routine>/<input_size>/<competitor>/<device>-run<N>/runtimes

Each runtimes file contains one runtime value (nanoseconds) per line.
The "data" competitor folder is ignored.

Output: a single PDF with one subplot per (device, routine) combination,
each showing speedup box plots of non-baseline competitors relative to baseline.
"""
import argparse
import re
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def natural_sort_key(s: str):
    return [int(c) if c.isdigit() else c.lower() for c in re.split(r"(\d+)", s)]


def discover_data(
    experiment_dir: Path,
) -> dict[tuple[str, str, str, str], list[float]]:
    """
    Walk experiment_dir/<routine>/<input_size>/<competitor>/<device>-run<N>/runtimes
    and return {(routine, input_size, competitor, device): [runtimes]}.
    """
    data: dict[tuple[str, str, str, str], list[float]] = defaultdict(list)

    for routine_dir in sorted(experiment_dir.iterdir()):
        if not routine_dir.is_dir():
            continue
        for is_dir in sorted(routine_dir.iterdir()):
            if not is_dir.is_dir():
                continue
            for comp_dir in sorted(is_dir.iterdir()):
                if not comp_dir.is_dir() or comp_dir.name == "data":
                    continue
                for run_dir in sorted(comp_dir.iterdir()):
                    if not run_dir.is_dir():
                        continue
                    m = re.match(r"^(.+)-run(\d+)$", run_dir.name)
                    if not m:
                        continue
                    device = m.group(1)
                    runtimes_file = run_dir / "runtimes"
                    if not runtimes_file.is_file():
                        continue
                    key = (routine_dir.name, is_dir.name, comp_dir.name, device)
                    with open(runtimes_file) as f:
                        for line in f:
                            line = line.strip()
                            if line:
                                try:
                                    data[key].append(float(line))
                                except ValueError:
                                    pass

    return dict(data)


def compute_speedups(
    data: dict[tuple[str, str, str, str], list[float]],
    routine: str,
    input_size: str,
    device: str,
    competitors: list[str],
) -> dict[str, list[float]]:
    """
    For each non-baseline competitor, compute speedup values as
    median(baseline_runtimes) / competitor_runtime.
    """
    baseline_rts = data.get((routine, input_size, "baseline", device), [])
    if not baseline_rts:
        return {}

    baseline_median = float(np.median(baseline_rts))
    result: dict[str, list[float]] = {}
    for comp in competitors:
        if comp == "baseline":
            continue
        rts = data.get((routine, input_size, comp, device), [])
        if rts:
            result[comp] = [baseline_median / rt for rt in rts]
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot competitor speedup over baseline from experiment results."
    )
    parser.add_argument("experiment_dir", type=Path, help="Root experiment folder")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("runtimes.pdf"),
        help="Output PDF path (default: runtimes.pdf)",
    )
    args = parser.parse_args()

    data = discover_data(args.experiment_dir.resolve())
    if not data:
        raise SystemExit("No runtime data found.")

    routines = sorted({k[0] for k in data}, key=natural_sort_key)
    devices = sorted({k[3] for k in data}, key=natural_sort_key)
    competitors = sorted({k[2] for k in data}, key=natural_sort_key)
    nb_competitors = [c for c in competitors if c != "baseline"]
    if not nb_competitors:
        raise SystemExit("No non-baseline competitors found.")

    panels = [(d, r) for d in devices for r in routines]
    n = len(panels)
    ncols = min(n, 3)
    nrows = -(-n // ncols)

    fig, axes = plt.subplots(
        nrows, ncols, figsize=(6 * ncols, 4 * nrows), squeeze=False
    )

    cmap = plt.get_cmap("Set2")
    colors = {
        comp: cmap(i / max(len(nb_competitors) - 1, 1))
        for i, comp in enumerate(nb_competitors)
    }

    for idx, (device, routine) in enumerate(panels):
        ax = axes[idx // ncols][idx % ncols]
        input_sizes = sorted(
            {k[1] for k in data if k[0] == routine and k[3] == device},
            key=natural_sort_key,
        )

        group_width = len(nb_competitors)
        box_width = 0.6
        all_box_data: list[list[float]] = []
        all_positions: list[float] = []
        all_colors: list = []
        tick_positions: list[float] = []
        tick_labels: list[str] = []

        for g, is_name in enumerate(input_sizes):
            speedups = compute_speedups(data, routine, is_name, device, competitors)
            group_start = g * (group_width + 1)
            for j, comp in enumerate(nb_competitors):
                if comp in speedups:
                    all_positions.append(group_start + j)
                    all_box_data.append(speedups[comp])
                    all_colors.append(colors[comp])
            tick_positions.append(group_start + (group_width - 1) / 2)
            tick_labels.append(is_name)

        if not all_box_data:
            ax.set_visible(False)
            continue

        bp = ax.boxplot(
            all_box_data,
            positions=all_positions,
            widths=box_width,
            patch_artist=True,
            whis=[5, 95],
        )
        for patch, c in zip(bp["boxes"], all_colors):
            patch.set_facecolor(c)

        ax.axhline(y=1.0, color="gray", linestyle="--", linewidth=0.8, zorder=0)
        ax.set_xticks(tick_positions)
        ax.set_xticklabels(tick_labels)
        ax.set_ylabel("Speedup over baseline")
        ax.set_title(f"{routine} ({device})")

    for idx in range(n, nrows * ncols):
        axes[idx // ncols][idx % ncols].set_visible(False)

    from matplotlib.patches import Patch

    legend_handles = [Patch(facecolor=colors[c], label=c) for c in nb_competitors]
    fig.legend(handles=legend_handles, loc="upper right")

    plt.tight_layout()
    fig.savefig(args.output, format="pdf", bbox_inches="tight")
    plt.close()
    print(f"Saved {args.output}")


if __name__ == "__main__":
    main()
