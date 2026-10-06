# MaleCNS v1.0 data

`neurons.bin`, `synapses.bin`, and `connectome.json` are derived locally from
the official MaleCNS v1.0 bulk exports. The raw Feather files are intentionally
ignored by git because the largest source is about 1.05 GB. Recreate them with
the pinned downloader and importer:

```sh
python3.11 -m venv .venv-malecns
.venv-malecns/bin/python -m pip install -r scripts/requirements-malecns.txt
.venv-malecns/bin/python scripts/fetch-malecns.py --import
```

The script verifies the exact source byte size and SHA-256 before importing.
The source files were fetched from the public [MaleCNS download
page](https://male-cns.janelia.org/download/) on 2026-10-02:

| Source | Bytes | SHA-256 |
| --- | ---: | --- |
| `body-annotations-male-cns-v1.0-minconf-0.5.feather` | 14,483,314 | `2177e246113e4cfbf1e7772ec37c6da1955ff22e8063d0b1f833101f99a9a3b2` |
| `body-neurotransmitters-male-cns-v1.0.feather` | 43,282,834 | `95c9289220663abeb3409f3ad9e5a7f8a53f8093f5139d15502cd08da8879621` |
| `connectome-weights-male-cns-v1.0-minconf-0.5.feather` | 1,051,241,946 | `e35da783d1c686b2b58b3b87cd6a403ae43bfcfba8bff28e08ef752c1a56afc1` |

The MaleCNS data are released under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Please attribute the FlyEM project at HHMI Janelia, the University of
Cambridge, the MRC Laboratory of Molecular Biology, and Google Research, and
cite [Berg et al., *Sexual dimorphism in the complete connectome of the
Drosophila male central nervous system*](https://pmc.ncbi.nlm.nih.gov/articles/PMC12636603/).

## Import boundary and counts

The v1.0 annotation export contains 211,577 body rows. The importer retains
every row with a non-null `superclass`, which is the explicit annotated-neuron
boundary in this release: **166,700 bodies**. Rows with null `superclass` are
not silently turned into neurons; they are excluded as unannotated fragments,
glia, anchors, or other segments in the source export.

The full connection export has 151,856,684 segment-level rows. The importer
keeps every row whose pre and post body IDs are both in the 166,700-body
annotated set, then aggregates repeated body pairs. For this release that
produces 25,582,938 internal CSR edges, with 126,273,746 source rows excluded
because at least one endpoint is outside the annotated set. No connection
threshold or artificial edge is added; the current source has no duplicate
body pairs after this boundary filter.

Soma coordinates come from `somaLocation` in source voxel units when present;
missing coordinates are stored as `(0, 0, 0)` placeholders and are not used by
the neural dynamics. `somaSide` is preferred, with `rootSide` as the sensory
fallback.

The packaged neural mapping uses the annotated MaleCNS types directly: `ORN_DM1`
and `DM1_lPN` for the bilateral odor path, `LB3c` for taste, `LC4` for looming,
`JO-A-unclear`/`JO-B-unclear` for touch, `MN9` for feeding, `DNp01` for the
Giant Fiber escape readout, `DNg11` for grooming, and `DNg02_[a-g]` for the
bilateral flight readout. `DNp09` is used for forward drive based on the P9
forward pathway ([Liu et al.](https://pubmed.ncbi.nlm.nih.gov/32822613/));
`DNa01` and `DNa02` are combined per soma side as the bilateral steering
readout ([Hsu et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC12279373/)).
These are output/input selectors over actual MaleCNS body IDs, not added
neurons or synthetic edges.

## Signed graph convention

The official weights are positive synaptic contact strengths, not signed
physiological efficacies. The importer applies an explicit model convention
to the presynaptic `consensus_nt`: acetylcholine positive, GABA and glutamate
negative, dopamine/serotonin/octopamine positive as the existing engine’s
modulatory convention, and unclear positive as an explicit unknown fallback.
Histamine is retained and counted separately; it is assigned a negative LIF
sign as an explicit adapter assumption informed by histamine-gated chloride
conductance literature ([Zettler et al.](https://pubmed.ncbi.nlm.nih.gov/2472552/);
[Pantazis et al.](https://pubmed.ncbi.nlm.nih.gov/18632929/)). This does not
claim a universal postsynaptic effect for every MaleCNS circuit. The source
counts and this policy are recorded in `connectome.json`.

No weight clipping is performed. The generated signed range is `[-2591, 1878]`,
which fits the current Int16 CSR contract.
