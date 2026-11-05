# `tests/prove/`

- **Purpose:** SPARK projects for `./x prove`.
- **License:** Apache-2.0

| Directory | Content |
|---|---|
| `sample/` | `Sample_Math`, proved free of run-time errors with contracts that state the result. Listed in `tools/prove.list`. |
| `tlsf/` | `Tlsf_Math` (size classes and bit arithmetic of the TLSF allocator: the bucket indices are always in range) and `Heap_Guard` (request sizes of `malloc` and `calloc`: a request that wraps never gives a block that is too small), the SPARK units of the heap of the embedded runtime. The project names the sources of `crates/mpfs_rts/overlays/tlsf`, not copies. Two rows of `tools/prove.list`, one per unit. |
| `fixtures/unprovable/` | A project with an overflow that cannot be proved. Not in `tools/prove.list`: `tests/host/prove/run.sh` runs `tools/prove.sh` on it and requires a failure. |
