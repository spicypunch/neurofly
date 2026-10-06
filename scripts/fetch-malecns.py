#!/usr/bin/env python3
"""Fetch and import the official Male CNS v1.0 whole-CNS graph.

The source files are public Feather exports from Janelia's Male CNS portal.
Raw files stay outside git; this script pins their byte sizes and SHA-256
digests before allowing an import.  The importer keeps every annotated body
and every internal body-to-body connection, aggregates duplicate rows, and
emits the compact CSR contract consumed by NeuroFly.

Requires the isolated reference environment (or another environment with
pyarrow and numpy):

    .venv-reference/bin/python scripts/fetch-malecns.py --download-only
    .venv-reference/bin/python scripts/fetch-malecns.py --import

The importer intentionally fails closed for a changed source checksum or for
weights that cannot be represented without clipping in the current Int16
engine contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data" / "malecns"
RAW_DIR = DATA_DIR / "raw"

BASE_URL = (
    "https://storage.googleapis.com/flyem-male-cns/v1.0/"
    "connectome-data/flat-connectome"
)

# Pinned against the public v1.0 objects fetched on 2026-10-02.  A changed
# release must be inspected and deliberately repinned; it is never accepted
# silently.
FILES = {
    "body-annotations-male-cns-v1.0-minconf-0.5.feather": {
        "bytes": 14_483_314,
        "sha256": "2177e246113e4cfbf1e7772ec37c6da1955ff22e8063d0b1f833101f99a9a3b2",
        "purpose": "body annotations, types, sides and coordinates",
    },
    "body-neurotransmitters-male-cns-v1.0.feather": {
        "bytes": 43_282_834,
        "sha256": "95c9289220663abeb3409f3ad9e5a7f8a53f8093f5139d15502cd08da8879621",
        "purpose": "per-body neurotransmitter predictions",
    },
    "connectome-weights-male-cns-v1.0-minconf-0.5.feather": {
        "bytes": 1_051_241_946,
        "sha256": "e35da783d1c686b2b58b3b87cd6a403ae43bfcfba8bff28e08ef752c1a56afc1",
        "purpose": "complete min-confidence body connection graph",
    },
}

ANNOTATION_NAME = next(name for name in FILES if name.startswith("body-annotations"))
NT_NAME = next(name for name in FILES if name.startswith("body-neurotransmitters"))
WEIGHT_NAME = next(name for name in FILES if name.startswith("connectome-weights"))

# Explicit policy for the app's current signed CSR format.  This is a model
# convention applied to positive MaleCNS connection strengths; it is not a
# claim that every downstream synapse has a fixed effect in vivo.
NT_SIGN = {
    "acetylcholine": 1,
    "gaba": -1,
    "glutamate": -1,
    "dopamine": 1,
    "serotonin": 1,
    "octopamine": 1,
    # Drosophila histamine is treated as inhibitory in this LIF adapter based
    # on histamine-gated chloride conductance reports; the connectome itself
    # supplies identity, not a universal postsynaptic sign.
    "histamine": -1,
    "unclear": 1,
    "unknown": 1,
    "": 1,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_one(name: str, metadata: dict[str, object]) -> None:
    expected_bytes = int(metadata["bytes"])
    expected_sha = str(metadata["sha256"])
    if len(expected_sha) != 64:
        raise RuntimeError(
            f"{name}: SHA-256 pin is missing; refusing to download an unpinned source"
        )
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    target = RAW_DIR / name
    if target.is_file() and target.stat().st_size == expected_bytes:
        actual = sha256(target)
        if actual == expected_sha:
            print(f"verified {name} ({expected_bytes} bytes)")
            return
        raise RuntimeError(f"{name}: existing file SHA-256 mismatch: {actual}")

    partial = target.with_suffix(target.suffix + ".partial")
    partial.unlink(missing_ok=True)
    url = f"{BASE_URL}/{name}"
    print(f"downloading {url}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "NeuroFly/1.0"})
    total = 0
    try:
        with urllib.request.urlopen(request, timeout=120) as source, partial.open("wb") as output:
            while True:
                chunk = source.read(4 * 1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > expected_bytes:
                    raise RuntimeError(f"{name}: source exceeded pinned byte size")
                output.write(chunk)
                if total % (128 * 1024 * 1024) < len(chunk):
                    print(f"  {total / 1024 / 1024:.0f} MiB", flush=True)
        if total != expected_bytes:
            raise RuntimeError(f"{name}: expected {expected_bytes} bytes, got {total}")
        actual = sha256(partial)
        if actual != expected_sha:
            raise RuntimeError(f"{name}: SHA-256 mismatch: expected {expected_sha}, got {actual}")
        os.replace(partial, target)
        print(f"downloaded and verified {name}", flush=True)
    finally:
        partial.unlink(missing_ok=True)


def require_pyarrow_numpy():
    try:
        import numpy as np  # type: ignore
        import pyarrow as pa  # type: ignore
        import pyarrow.feather as feather  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "MaleCNS import requires pyarrow and numpy in an isolated environment"
        ) from exc
    return np, pa, feather


def choose_column(names: Iterable[str], *candidates: str) -> str:
    available = set(names)
    for candidate in candidates:
        if candidate in available:
            return candidate
    raise RuntimeError(f"none of columns {candidates!r} found; available={sorted(available)!r}")


def normalize_text(value: object) -> str:
    if value is None:
        return ""
    return str(value).strip()


def side_value(row: dict[str, object]) -> str:
    """Prefer somaSide, then rootSide, matching the MaleCNS definition."""
    return normalize_text(row.get("somaSide")) or normalize_text(row.get("rootSide"))


def query_rows(table, columns: list[str]) -> list[dict[str, object]]:
    # This helper is deliberately used only for the small annotation tables.
    selected = table.select(columns)
    pydict = selected.to_pydict()
    return [dict(zip(columns, values)) for values in zip(*(pydict[c] for c in columns))]


def body_id_map(annotation, nt_table):
    import numpy as np  # type: ignore

    names = annotation.column_names
    body_col = choose_column(names, "bodyId", "body_id", "rootId", "root_id")
    type_col = choose_column(names, "type", "cellType", "cell_type")
    instance_col = choose_column(names, "instance", "label", "name")
    superclass_col = choose_column(names, "superclass", "superClass")
    # The official v1.0 export stores soma coordinates as a list in voxel
    # units. Sensory axons and bodies without a measured soma have null here;
    # those rows receive the explicit zero renderer placeholder.
    position_col = "somaLocation" if "somaLocation" in names else None
    soma_col = next((c for c in ("somaSide", "soma_side") if c in names), None)
    root_col = next((c for c in ("rootSide", "root_side") if c in names), None)
    subclass_col = next((c for c in ("subclass", "sub_class") if c in names), None)

    nt_names = nt_table.column_names
    nt_body_col = choose_column(nt_names, "body", "bodyId", "body_id", "rootId", "root_id")
    # consensus_nt is the official recommended body-level value. The source
    # table has one row per segmented body, not one row per annotated neuron.
    nt_col = choose_column(nt_names, "consensus_nt", "consensusNt", "predicted_nt", "predictedNt")
    nt_body_values = np.asarray(nt_table[nt_body_col].combine_chunks())
    nt_values = nt_table[nt_col].combine_chunks().to_pylist()
    nt_by_body = {
        int(body): normalize_text(value).lower()
        for body, value in zip(nt_body_values, nt_values)
    }

    requested = [body_col, type_col, instance_col]
    for c in (superclass_col, soma_col, root_col, subclass_col, position_col):
        if c and c not in requested:
            requested.append(c)
    rows = query_rows(annotation, requested)
    bodies: list[dict[str, object]] = []
    index_by_body: dict[int, int] = {}
    for row in rows:
        # MaleCNS v1.0 has 211,577 body rows. A non-null superclass is the
        # published annotated-neuron boundary: it retains all 166,700 v1.0
        # neurons and excludes explicit unannotated fragments/glia rows.
        if row.get(superclass_col) is None:
            continue
        body = int(row[body_col])
        if body in index_by_body:
            raise RuntimeError(f"duplicate annotated bodyId {body}")
        index_by_body[body] = len(bodies)
        position = row.get(position_col) if position_col else None
        if isinstance(position, (list, tuple)) and len(position) == 3:
            pos = [float(value) if value is not None else 0.0 for value in position]
        else:
            pos = [0.0, 0.0, 0.0]
        bodies.append(
            {
                "bodyId": body,
                "type": normalize_text(row[type_col]),
                "instance": normalize_text(row[instance_col]),
                "superclass": normalize_text(row[superclass_col]),
                "somaSide": normalize_text(row.get(soma_col)) if soma_col else "",
                "rootSide": normalize_text(row.get(root_col)) if root_col else "",
                "subclass": normalize_text(row.get(subclass_col)) if subclass_col else "",
                "nt": nt_by_body.get(body, "unclear"),
                "pos": pos,
            }
        )
    if not bodies:
        raise RuntimeError("body annotation export is empty")
    return bodies, index_by_body, {
        "bodyId": body_col,
        "type": type_col,
        "instance": instance_col,
        "superclass": superclass_col,
        "coordinates": position_col,
        "somaSide": soma_col,
        "rootSide": root_col,
        "neurotransmitter": {"body": nt_body_col, "value": nt_col},
    }


def signed_nt(nt: str) -> int:
    nt = normalize_text(nt).lower()
    return NT_SIGN.get(nt, 1)


def selector(bodies: list[dict[str, object]], predicate, label: str) -> list[int]:
    values = [int(row["bodyId"]) for row in bodies if predicate(row)]
    if not values:
        raise RuntimeError(f"neural mapping selector {label} matched no bodies")
    return values


def build_mapping(bodies: list[dict[str, object]]) -> tuple[dict[str, list[int]], dict[str, int]]:
    def side(row: dict[str, object]) -> str:
        # ORNs are the known exception: rootSide describes their nerve entry.
        return normalize_text(row.get("rootSide")) or normalize_text(row.get("somaSide"))

    def typ(row: dict[str, object]) -> str:
        return normalize_text(row.get("type"))

    def exact_type(value: str):
        return lambda row: typ(row) == value

    mapping = {
        "odorLeft": selector(bodies, lambda r: typ(r) == "ORN_DM1" and side(r) == "L", "ORN_DM1/L"),
        "odorRight": selector(bodies, lambda r: typ(r) == "ORN_DM1" and side(r) == "R", "ORN_DM1/R"),
        "odorRelayLeft": selector(bodies, lambda r: typ(r) == "DM1_lPN" and side(r) == "L", "DM1_lPN/L"),
        "odorRelayRight": selector(bodies, lambda r: typ(r) == "DM1_lPN" and side(r) == "R", "DM1_lPN/R"),
        "taste": selector(bodies, lambda r: typ(r) == "LB3c", "LB3c sugar"),
        "loomingLeft": selector(bodies, lambda r: typ(r) == "LC4" and side(r) == "L", "LC4/L"),
        "loomingRight": selector(bodies, lambda r: typ(r) == "LC4" and side(r) == "R", "LC4/R"),
        "touch": selector(
            bodies,
            lambda r: typ(r) in {"JO-A-unclear", "JO-B-unclear"},
            "JO-A/JO-B unclear mechanosensory",
        ),
        # DNp09 is the forward descending pathway. DNa01/DNa02 are kept
        # together as the bilateral steering readout for each side.
        "turnLeft": selector(
            bodies, lambda r: typ(r) in {"DNa01", "DNa02"} and side(r) == "L", "DNa01/DNa02/L"
        ),
        "turnRight": selector(
            bodies, lambda r: typ(r) in {"DNa01", "DNa02"} and side(r) == "R", "DNa01/DNa02/R"
        ),
        "forward": selector(bodies, lambda r: typ(r) == "DNp09", "DNp09/P9 forward"),
        "escape": selector(bodies, lambda r: typ(r) == "DNp01", "DNp01/GF"),
        "feeding": selector(bodies, lambda r: typ(r) == "MN9", "MN9"),
        "grooming": selector(bodies, lambda r: typ(r) == "DNg11", "DNg11"),
        "flightLeft": selector(
            bodies, lambda r: re.fullmatch(r"DNg02_[a-g]", typ(r)) is not None and side(r) == "L", "DNg02/L"
        ),
        "flightRight": selector(
            bodies, lambda r: re.fullmatch(r"DNg02_[a-g]", typ(r)) is not None and side(r) == "R", "DNg02/R"
        ),
    }
    all_ids: dict[int, str] = {}
    for name, ids in mapping.items():
        for body in ids:
            if body in all_ids:
                raise RuntimeError(f"neural mapping overlap: {all_ids[body]} and {name} at bodyId {body}")
            all_ids[body] = name
    return mapping, {name: len(ids) for name, ids in mapping.items()}


def import_graph() -> None:
    np, pa, feather = require_pyarrow_numpy()
    import pyarrow.ipc as ipc  # type: ignore

    annotations = feather.read_table(RAW_DIR / ANNOTATION_NAME)
    nts = feather.read_table(RAW_DIR / NT_NAME)
    bodies, index_by_body, source_columns = body_id_map(annotations, nts)
    mapping, mapping_counts = build_mapping(bodies)

    weight_path = RAW_DIR / WEIGHT_NAME
    reader = ipc.open_file(pa.memory_map(str(weight_path), "r"))
    cols = reader.schema.names
    pre_col = choose_column(cols, "body_pre", "bodyId_pre", "pre_bodyId", "body_id_pre")
    post_col = choose_column(cols, "body_post", "bodyId_post", "post_bodyId", "body_id_post")
    weight_col = choose_column(cols, "weight", "syn_count", "synapse_count", "count")
    pre_column = cols.index(pre_col)
    post_column = cols.index(post_col)
    weight_column = cols.index(weight_col)

    # The official full table has 151,856,684 segment-level rows. Filter each
    # batch at the annotated-neuron boundary before retaining arrays, then
    # aggregate repeated (pre, post) body pairs below. This avoids loading an
    # extra full-table copy while preserving every internal connection.
    body_ids = np.fromiter(index_by_body.keys(), dtype=np.int64, count=len(index_by_body))
    dense = np.arange(len(body_ids), dtype=np.int64)
    order = np.argsort(body_ids)
    sorted_body_ids = body_ids[order]
    sorted_dense = dense[order]
    pre_parts = []
    post_parts = []
    raw_weight_parts = []
    source_row_count = 0
    excluded_source_rows = 0
    for batch_index in range(reader.num_record_batches):
        batch = reader.get_batch(batch_index)
        pre = np.asarray(batch.column(pre_column))
        post = np.asarray(batch.column(post_column))
        raw_weight = np.asarray(batch.column(weight_column))
        if len(pre) != len(post) or len(pre) != len(raw_weight):
            raise RuntimeError(f"weight columns differ in batch {batch_index}")
        source_row_count += len(pre)
        if np.any(raw_weight <= 0):
            raise RuntimeError(f"source graph contains non-positive weights in batch {batch_index}")
        pre_pos = np.searchsorted(sorted_body_ids, pre)
        post_pos = np.searchsorted(sorted_body_ids, post)
        pre_valid = (pre_pos < len(sorted_body_ids))
        post_valid = (post_pos < len(sorted_body_ids))
        pre_valid &= sorted_body_ids[np.minimum(pre_pos, len(sorted_body_ids) - 1)] == pre
        post_valid &= sorted_body_ids[np.minimum(post_pos, len(sorted_body_ids) - 1)] == post
        internal = pre_valid & post_valid
        excluded_source_rows += int((~internal).sum())
        if internal.any():
            pre_parts.append(sorted_dense[pre_pos[internal]])
            post_parts.append(sorted_dense[post_pos[internal]])
            raw_weight_parts.append(raw_weight[internal].astype(np.int64, copy=False))
    if not pre_parts:
        raise RuntimeError("no internal annotated-neuron edges remain after filtering")
    pre_idx = np.concatenate(pre_parts)
    post_idx = np.concatenate(post_parts)
    raw_weight = np.concatenate(raw_weight_parts)
    if len(pre_idx) != source_row_count - excluded_source_rows:
        raise RuntimeError("internal row accounting mismatch")

    # Signed body-level policy. The output is not clipped: if duplicate
    # aggregation or source weights overflow Int16, abort for an engine schema
    # change rather than manufacturing a different graph.
    nt_sign_by_dense = np.fromiter((signed_nt(row["nt"]) for row in bodies), dtype=np.int64)
    signed = raw_weight.astype(np.int64) * nt_sign_by_dense[pre_idx]
    pair_key = pre_idx.astype(np.int64) * len(bodies) + post_idx.astype(np.int64)
    pair_order = np.argsort(pair_key, kind="mergesort")
    pair_key = pair_key[pair_order]
    signed = signed[pair_order]
    starts = np.r_[0, np.flatnonzero(pair_key[1:] != pair_key[:-1]) + 1]
    agg_key = pair_key[starts]
    agg_weight = np.add.reduceat(signed, starts)
    internal_source_row_count = len(pre_idx)
    duplicate_row_count = internal_source_row_count - len(agg_key)
    if np.any(agg_weight == 0):
        raise RuntimeError("signed aggregation produced a zero edge; sign cancellation is not representable")
    min_weight = int(agg_weight.min())
    max_weight = int(agg_weight.max())
    if min_weight < -32768 or max_weight > 32767:
        raise RuntimeError(
            "MaleCNS signed edge weights exceed Int16; no clipping was performed "
            f"(min={min_weight}, max={max_weight}). Coordinate Metal/Connectome schema upgrade first."
        )

    n = len(bodies)
    src_idx = agg_key // n
    dst_idx = agg_key % n
    row_start = np.zeros(n + 1, dtype=np.uint32)
    np.add.at(row_start, src_idx + 1, 1)
    np.cumsum(row_start, out=row_start)
    col_idx = dst_idx.astype(np.uint32)
    weight = agg_weight.astype(np.int16)

    out = DATA_DIR
    out.mkdir(parents=True, exist_ok=True)
    neurons_path = out / "neurons.bin"
    synapses_path = out / "synapses.bin"
    # Positions are source somaLocation values in 8nm voxel units. Sensory
    # axons and rows without a measured soma remain zero placeholders; they are
    # not inferred or used to alter neural dynamics.
    positions = np.asarray([value for row in bodies for value in row["pos"]], dtype="<f4")
    super_classes = sorted({normalize_text(row["superclass"]) for row in bodies})
    sides = ["center", "left", "right", "unknown"]
    nts = ["UNKNOWN", "ACH", "GABA", "GLUT", "DA", "SER", "OCT", "HISTAMINE"]
    roles = ["other"]
    cell_types = sorted({normalize_text(row["type"]) or "unknown" for row in bodies})
    super_id = {value: i for i, value in enumerate(super_classes)}
    side_id = {"": 3, "L": 1, "R": 2, "M": 0}
    nt_id = {"": 0, "unclear": 0, "unknown": 0, "acetylcholine": 1, "gaba": 2,
             "glutamate": 3, "dopamine": 4, "serotonin": 5, "octopamine": 6,
             "histamine": 7}
    type_id = {value: i for i, value in enumerate(cell_types)}
    super_arr = np.asarray([super_id[row["superclass"]] for row in bodies], dtype=np.uint8)
    side_arr = np.asarray([side_id.get(side_value(row), 3) for row in bodies], dtype=np.uint8)
    nt_arr = np.asarray([nt_id.get(normalize_text(row["nt"]).lower(), 0) for row in bodies], dtype=np.uint8)
    role_arr = np.zeros(n, dtype=np.uint8)
    cell_arr = np.asarray([type_id[normalize_text(row["type"]) or "unknown"] for row in bodies], dtype=np.uint16)
    body_ids_dense = np.asarray([int(row["bodyId"]) for row in bodies], dtype="<u8")

    def write_arrays(path: Path, chunks: list[object]) -> list[int]:
        offsets: list[int] = []
        offset = 0
        partial = path.with_suffix(path.suffix + ".partial")
        with partial.open("wb") as stream:
            for chunk in chunks:
                offsets.append(offset)
                payload = chunk.tobytes(order="C")
                stream.write(payload)
                offset += len(payload)
        os.replace(partial, path)
        return offsets

    neuron_offsets = write_arrays(
        neurons_path,
        [positions, super_arr, side_arr, nt_arr, role_arr, cell_arr, body_ids_dense],
    )
    synapse_offsets = write_arrays(synapses_path, [row_start, col_idx, weight])
    nt_counts = Counter(normalize_text(row["nt"]).lower() or "unclear" for row in bodies)

    manifest = {
        "format": "desktopfly-connectome-1",
        "generated": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        "neuronCount": n,
        "edgeCount": int(len(agg_key)),
        "synapseTotal": int(np.abs(agg_weight).sum()),
        "sourceRows": source_row_count,
        "internalSourceRows": internal_source_row_count,
        "excludedUnannotatedSourceRows": excluded_source_rows,
        "duplicateRowsAggregated": duplicate_row_count,
        "rawInternalSynapseTotal": int(raw_weight.sum()),
        "rawWeightRange": {"min": int(raw_weight.min()), "max": int(raw_weight.max())},
        "signedWeightRange": {"min": min_weight, "max": max_weight},
        "minSyn": 1,
        "byteOrder": "little",
        "files": {
            "neurons.bin": {"bytes": neurons_path.stat().st_size, "sha256": sha256(neurons_path)},
            "synapses.bin": {"bytes": synapses_path.stat().st_size, "sha256": sha256(synapses_path)},
        },
        "arrays": {
            "pos": {"file": "neurons.bin", "byteOffset": neuron_offsets[0], "dtype": "float32", "count": n * 3, "components": 3},
            "superClass": {"file": "neurons.bin", "byteOffset": neuron_offsets[1], "dtype": "uint8", "count": n, "components": 1},
            "side": {"file": "neurons.bin", "byteOffset": neuron_offsets[2], "dtype": "uint8", "count": n, "components": 1},
            "nt": {"file": "neurons.bin", "byteOffset": neuron_offsets[3], "dtype": "uint8", "count": n, "components": 1},
            "role": {"file": "neurons.bin", "byteOffset": neuron_offsets[4], "dtype": "uint8", "count": n, "components": 1},
            "cellType": {"file": "neurons.bin", "byteOffset": neuron_offsets[5], "dtype": "uint16", "count": n, "components": 1},
            "rootId": {"file": "neurons.bin", "byteOffset": neuron_offsets[6], "dtype": "uint64", "count": n, "components": 1},
            "rowStart": {"file": "synapses.bin", "byteOffset": synapse_offsets[0], "dtype": "uint32", "count": n + 1, "components": 1},
            "colIdx": {"file": "synapses.bin", "byteOffset": synapse_offsets[1], "dtype": "uint32", "count": len(agg_key), "components": 1},
            "weight": {"file": "synapses.bin", "byteOffset": synapse_offsets[2], "dtype": "int16", "count": len(agg_key), "components": 1},
        },
        "stringTables": {
            "superClasses": super_classes,
            "sides": sides,
            "nts": nts,
            "roles": roles,
            "cellTypes": cell_types,
        },
        "ntSign": NT_SIGN,
        "ntCounts": dict(sorted(nt_counts.items())),
        "modulatoryNts": ["DA", "SER", "OCT"],
        "roleCounts": {"other": n},
        "dataset": {
            "id": "malecns",
            "displayName": "Male CNS v1.0",
            "version": "v1.0|minconf-0.5",
            "source": "https://male-cns.janelia.org/download/",
        },
        "neuralMapping": mapping,
        "provenance": {
            "annotationFile": ANNOTATION_NAME,
            "neurotransmitterFile": NT_NAME,
            "weightFile": WEIGHT_NAME,
            "sourceColumns": source_columns,
            "coordinatePolicy": "source somaLocation voxel coordinates when present; otherwise all zeros are unused renderer placeholders",
            "sidePolicy": "somaSide where present, rootSide fallback for sensory neurons",
            "annotationFilter": "retain every body-annotations row with non-null superclass (166,700 v1.0 annotated bodies); exclude rows with null superclass as unannotated fragments/glia/segments. The publication reports 166,691 neurons; this importer records the pinned v1.0 export and its explicit filter instead of forcing that published count.",
            "weightPolicy": "positive source strengths signed by presynaptic consensus_nt: ACH +, GABA/GLUT -, histamine -, DA/SER/OCT + as existing engine convention, unclear + as an explicit unknown fallback; histamine sign is an LIF assumption informed by chloride conductance literature, not a universal postsynaptic claim",
            "histamineReference": "https://pubmed.ncbi.nlm.nih.gov/2472552/; https://pubmed.ncbi.nlm.nih.gov/18632929/",
            "mappingEvidence": "MaleCNS v1.0 annotation type/bodyId selectors; LB3c sugar selector follows Tastekin et al. Cell 2026; DNp09 forward follows https://pubmed.ncbi.nlm.nih.gov/32822613/ and DNa01/DNa02 bilateral steering follows https://pmc.ncbi.nlm.nih.gov/articles/PMC12279373/",
        },
    }
    manifest_path = out / "connectome.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({
        "neuronCount": n,
        "sourceRows": source_row_count,
        "edgeCount": int(len(agg_key)),
        "duplicateRowsAggregated": duplicate_row_count,
        "minWeight": min_weight,
        "maxWeight": max_weight,
        "mappingCounts": mapping_counts,
        "internalSourceRows": internal_source_row_count,
        "excludedUnannotatedSourceRows": excluded_source_rows,
        "arraysBytes": neurons_path.stat().st_size + synapses_path.stat().st_size,
        "neuronsSha256": manifest["files"]["neurons.bin"]["sha256"],
        "synapsesSha256": manifest["files"]["synapses.bin"]["sha256"],
    }, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--import", dest="do_import", action="store_true")
    args = parser.parse_args()
    if not args.download_only and not args.do_import:
        args.download_only = True
    for name, metadata in FILES.items():
        download_one(name, metadata)
    if args.do_import:
        import_graph()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"fetch-malecns: ERROR: {exc}", file=sys.stderr)
        raise
