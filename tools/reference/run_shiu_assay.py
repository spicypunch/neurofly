#!/usr/bin/env python3
"""Run a small, reproducible assay using Shiu et al.'s published model.

This script intentionally imports the upstream ``model.py`` from a disposable
checkout instead of copying or modifying it.  The model and the 630
connectome data are supplied through command-line paths so that the app's
SiliconFly engine stays completely separate from this reference run.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
import time
from pathlib import Path


SUGAR_IDS = [
    720575940624963786,
    720575940630233916,
    720575940637568838,
    720575940638202345,
    720575940617000768,
    720575940630797113,
    720575940632889389,
    720575940621754367,
    720575940621502051,
    720575940640649691,
    720575940639332736,
    720575940616885538,
    720575940639198653,
    720575940620900446,
    720575940617937543,
    720575940632425919,
    720575940633143833,
    720575940612670570,
    720575940628853239,
    720575940629176663,
    720575940611875570,
]
MN9_ID = 720575940660219265
EXPECTED_MODEL_SHA = "91bdd1e7dcf193f3e7ca5a8933497fcef63b7960"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--path-comp", type=Path, required=True)
    parser.add_argument("--path-con", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("baseline", "sugar"), required=True)
    parser.add_argument(
        "--experiment-name",
        help="Unique upstream run/output name; defaults to the JSON filename stem.",
    )
    parser.add_argument("--duration-ms", type=float, default=100.0)
    parser.add_argument("--trials", type=int, default=2)
    parser.add_argument("--input-hz", type=float, default=150.0)
    parser.add_argument("--n-proc", type=int, default=1)
    parser.add_argument("--seed", type=int, default=20261002)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    upstream = args.upstream.resolve()
    try:
        actual_model_sha = subprocess.run(
            ["git", "-C", str(upstream), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        dirty_model = subprocess.run(
            ["git", "-C", str(upstream), "status", "--porcelain", "--", "model.py"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(
            f"upstream must be a Git checkout of {EXPECTED_MODEL_SHA}"
        ) from exc
    if actual_model_sha != EXPECTED_MODEL_SHA:
        raise RuntimeError(
            f"unsupported upstream HEAD {actual_model_sha}; "
            f"expected {EXPECTED_MODEL_SHA}"
        )
    if dirty_model:
        raise RuntimeError("upstream model.py has uncommitted changes")
    sys.path.insert(0, str(upstream))

    # Importing Brian before the upstream model allows us to select its
    # portable NumPy runtime.  This changes execution backend only; equations,
    # graph, and parameters remain those in the published model.py.
    import numpy as np
    from brian2 import Hz, prefs, seed

    prefs.codegen.target = "numpy"
    np.random.seed(args.seed)
    seed(args.seed)
    from brian2 import ms
    import pandas as pd
    import model
    import utils

    params = dict(model.default_params)
    params["t_run"] = args.duration_ms * ms
    params["n_run"] = args.trials
    params["r_poi"] = args.input_hz * Hz

    args.output.parent.mkdir(parents=True, exist_ok=True)
    experiment_name = args.experiment_name or args.output.stem
    if not experiment_name or Path(experiment_name).name != experiment_name:
        raise ValueError("--experiment-name must be a non-empty filename stem")
    # ``run_exp`` names its output from ``exp_name``; keep the JSON summary
    # name independent so repeated runs do not make the parser guess.
    result_path = args.output.parent / f"{experiment_name}.parquet"
    selected = SUGAR_IDS if args.mode == "sugar" else []
    started = time.perf_counter()
    model.run_exp(
        exp_name=experiment_name,
        neu_exc=selected,
        path_res=args.output.parent,
        path_comp=args.path_comp,
        path_con=args.path_con,
        params=params,
        n_proc=args.n_proc,
        force_overwrite=True,
    )
    elapsed = time.perf_counter() - started

    spikes = pd.read_parquet(result_path)
    duration_s = args.duration_ms / 1000.0
    trial_count = args.trials
    total_spikes = len(spikes)
    active_neurons = int(spikes["flywire_id"].nunique()) if total_spikes else 0
    mn9_spikes = int((spikes["flywire_id"] == MN9_ID).sum())
    mn9_rate_hz = mn9_spikes / (duration_s * trial_count)
    trial_spike_counts = (
        spikes.groupby("trial").size().reindex(range(trial_count), fill_value=0).astype(int)
    )

    record = {
        "assay": "shiu_sugar_grn_to_mn9",
        "mode": args.mode,
        "experiment_name": experiment_name,
        "source": {
            "upstream_dir": str(upstream),
            "model_sha": actual_model_sha,
            "model_path": str(upstream / "model.py"),
            "notebook_path": str(upstream / "example.ipynb"),
            "data_version": "FlyWire 630",
            "path_comp": str(args.path_comp.resolve()),
            "path_con": str(args.path_con.resolve()),
            "result_path": str(result_path.resolve()),
        },
        "params": {
            "duration_ms": args.duration_ms,
            "trials": args.trials,
            "input_hz": args.input_hz,
            "n_proc": args.n_proc,
            "seed": args.seed,
            "codegen_target": prefs.codegen.target,
            "w_syn_mV": float(params["w_syn"] / (1 * model.mV)),
            "f_poi": params["f_poi"],
            "t_dly_ms": float(params["t_dly"] / (1 * model.ms)),
        },
        "counts": {
            "stimulated_neurons": len(selected),
            "spikes_total": total_spikes,
            "active_neurons": active_neurons,
            "mn9_id": MN9_ID,
            "mn9_spikes": mn9_spikes,
            "spikes_by_trial": [int(v) for v in trial_spike_counts.tolist()],
        },
        "rates_hz": {
            "mn9": mn9_rate_hz,
            "whole_network_mean_per_neuron": total_spikes / (duration_s * trial_count * 127400),
        },
        "elapsed_s": elapsed,
        "runtime": {
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "brian2": __import__("brian2").__version__,
            "pandas": pd.__version__,
        },
    }
    args.output.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
