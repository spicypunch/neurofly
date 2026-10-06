# MaleCNS importer

`fetch-malecns.py` downloads the three official MaleCNS v1.0 Feather files,
checks their pinned byte sizes and SHA-256 digests, and converts the complete
annotated-body graph to the app's CSR files. Raw downloads are written under
`data/malecns/raw/` and ignored by git.

Use Python 3.11 or another Python version with published wheels for both
PyArrow and NumPy; the system `python3` may be 3.14 on macOS and is not
assumed to work with every pinned PyArrow release.

For a clean checkout:

```sh
python3.11 -m venv .venv-malecns
.venv-malecns/bin/python -m pip install -r scripts/requirements-malecns.txt
.venv-malecns/bin/python scripts/fetch-malecns.py --download-only
.venv-malecns/bin/python scripts/fetch-malecns.py --import
```

The import records source rows whose endpoints are outside the explicit
annotated set as `excludedUnannotatedSourceRows`; those rows are expected in
the segment-level export and are not part of the packaged annotated CNS.
It fails closed when a source digest or required schema changes, a source
weight is non-positive, a neural mapping selector becomes empty or overlaps,
or a signed aggregate cannot fit Int16. It emits
`data/malecns/neurons.bin`, `synapses.bin`, and `connectome.json`.
