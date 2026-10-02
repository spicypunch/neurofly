# Shiu reference assay

This directory contains a bounded, independent check of the published Shiu
et al. Brian2 model. It imports the upstream `model.py` from a disposable Git
checkout and never modifies NeuroFly's Swift or Metal engine. The assay uses
only the published FlyWire v630 aggregate graph and completeness CSV; it does
not download raw EM volumes.

The runner enforces upstream commit
`91bdd1e7dcf193f3e7ca5a8933497fcef63b7960` and refuses a dirty `model.py`, so
the provenance written into each JSON record cannot silently drift.

## Recreate the environment

The original dependency file targets Python 3.10. On this Apple Silicon host,
Python 3.11 is used. Brian2 2.5.1 needs the legacy `pkg_resources` package at
build time, so keep `setuptools` below 81 and disable isolated build for that
package.

```sh
NEUROFLY_ROOT="$(pwd)" # Run from the NeuroFly repository root
REFERENCE_DIR=$(mktemp -d -t neurofly-shiu-reference)
git clone --filter=blob:none --no-checkout \
  https://github.com/philshiu/Drosophila_brain_model.git "$REFERENCE_DIR"
git -C "$REFERENCE_DIR" sparse-checkout init --no-cone
git -C "$REFERENCE_DIR" sparse-checkout set \
  model.py utils.py example.ipynb \
  2023_03_23_completeness_630_final.csv \
  2023_03_23_connectivity_630_final.parquet
git -C "$REFERENCE_DIR" checkout --detach \
  91bdd1e7dcf193f3e7ca5a8933497fcef63b7960

python3.11 -m venv "$NEUROFLY_ROOT/.venv-reference"
VENV="$NEUROFLY_ROOT/.venv-reference/bin/python"
"$VENV" -m pip install --upgrade pip
"$VENV" -m pip install 'setuptools<81' 'Cython<4'
"$VENV" -m pip install 'numpy<2' 'pandas<3' pyarrow joblib
"$VENV" -m pip install --no-build-isolation 'brian2==2.5.1'
```

The connectivity parquet is an aggregate graph (about 83 MB in the v630
checkout). Verify the source data if needed:

```sh
shasum -a 256 \
  "$REFERENCE_DIR/2023_03_23_completeness_630_final.csv" \
  "$REFERENCE_DIR/2023_03_23_connectivity_630_final.parquet"
```

Expected SHA-256 values:

| File | SHA-256 |
| --- | --- |
| Completeness CSV | `e6b71e17671a9bdb05f55e4bc6774640a1418cb7a05125e0fc994ad40f9bfdfb` |
| Connectivity parquet | `94db8c650533bc36ffa3223f2e62325d5648b8d6bd31c3a4e1c804628c7557b3` |

## Run

Use `--experiment-name` to keep each condition in its own parquet file. A seed
is included because Poisson GRN input is stochastic.

```sh
SCRIPT="$NEUROFLY_ROOT/tools/reference/run_shiu_assay.py"
mkdir -p "$NEUROFLY_ROOT/artifacts/reference"

"$VENV" "$SCRIPT" --upstream "$REFERENCE_DIR" \
  --path-comp "$REFERENCE_DIR/2023_03_23_completeness_630_final.csv" \
  --path-con "$REFERENCE_DIR/2023_03_23_connectivity_630_final.parquet" \
  --output "$NEUROFLY_ROOT/artifacts/reference/shiu-baseline.json" \
  --experiment-name shiu-baseline --mode baseline \
  --duration-ms 100 --trials 2 --input-hz 100 --n-proc 1 --seed 20261002

"$VENV" "$SCRIPT" --upstream "$REFERENCE_DIR" \
  --path-comp "$REFERENCE_DIR/2023_03_23_completeness_630_final.csv" \
  --path-con "$REFERENCE_DIR/2023_03_23_connectivity_630_final.parquet" \
  --output "$NEUROFLY_ROOT/artifacts/reference/shiu-sugar100.json" \
  --experiment-name shiu-sugar100 --mode sugar \
  --duration-ms 100 --trials 2 --input-hz 100 --n-proc 1 --seed 20261002

"$VENV" "$SCRIPT" --upstream "$REFERENCE_DIR" \
  --path-comp "$REFERENCE_DIR/2023_03_23_completeness_630_final.csv" \
  --path-con "$REFERENCE_DIR/2023_03_23_connectivity_630_final.parquet" \
  --output "$NEUROFLY_ROOT/artifacts/reference/shiu-sugar150.json" \
  --experiment-name shiu-sugar150 --mode sugar \
  --duration-ms 100 --trials 2 --input-hz 150 --n-proc 1 --seed 20261002
```

The generated JSON and parquet files stay in local `artifacts/reference/`.
In the recorded two-trial, 100 ms checks (seed 20261002), the baseline produced
zero spikes; sugar100 produced 1,688 total spikes and 50 Hz MN9 activity;
sugar150 produced 2,385 total spikes and 75 Hz MN9 activity. Repeating sugar100
with the same seed reproduced the counts. These are a reference for the
published Brian2 model, not a numerical equivalence claim for NeuroFly's Metal engine.
