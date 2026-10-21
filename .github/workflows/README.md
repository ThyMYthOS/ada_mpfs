# `.github/workflows/`

- **Purpose:** GitHub Actions workflows (logic lives in `./x`).

| Workflow | Job | Content |
|---|---|---|
| `registers.yml` | `svd` | Python 3.13 with the packages of `tools/requirements.txt`, `xmllint` and the pinned svdtools (`toolchain` action, target `svdtools`), then `./x svd check`, `tests/host/svd/run.sh` and `tests/host/x/run.sh`. Keeps the merged SVD as the artifact `svd`. |
| | `pac` (after `svd`) | Takes the artifact `svd` instead of merging again. The pinned GNAT, gprbuild, alr, svdtools and svd2ada (target `pac`, which skips gnatprove and adalang_analyzer), then `tests/host/pac/run.sh` and `./x pac check`. |
| `pac-regenerate.yml` | `regenerate` | Regenerates `libs/mpfs_pac/src/generated` with the pinned svd2ada and commits the result to the pull request branch. |
| `images.yml` | `build` | The pinned compilers (target `gnat`). `./x test examples` and `./x metrics verify` against `metrics.golden` build every image once, then `./x test negative` and the host suites that need no svdtools (`bare`, `report`, `negative`, `qemu_tests`, `stack`, `hw`, `analyze`, `prove` with its stand-in cases). Keeps the images as the artifact `images`. |
| | `qemu` (after `build`) | Ubuntu 26.04 with QEMU from apt. `./x test qemu` on the images of `build`: the smoke test and the `Test_Report` applications of `tests/qemu/tests.list`. Needs no toolchain and builds nothing (`MPFS_PREBUILT_IMAGES=1`). |
| | `renode` (after `build`) | The pinned Renode release with its SHA-256. `./x test renode` on the images of `build`. Needs no toolchain and builds nothing. Not required for a merge. |
| `quality.yml` | `prove` | The pinned compilers and the pinned gnatprove (target `gnatprove`), `./x prove`, and `tests/host/prove/run.sh` with the real gnatprove. `./x analyze` is not in a workflow yet: it needs the baselines in `tools/analyzer-baselines/`, which are written with the pinned adalang_analyzer (`./x analyze --update-baseline`, and with `--style`). |

| Workflow | Runs on |
|---|---|
| `registers.yml` | a push to any branch and a pull request against `main` that touch the SVD, the PAC, their tools, the host tests or the actions |
| `pac-regenerate.yml` | request (`workflow_dispatch`) and a pull request that changes the workflow or the actions |
| `images.yml` | a push to any branch and a pull request against `main` that touch the examples, `hw/`, the tests, the tools, `metrics.golden`, `x` or the actions |
| `quality.yml` | a push to any branch and a pull request against `main` that touch the proof projects, `tools/prove.*`, the pins, `libs/`, `x` or the actions |

The composite action `.github/actions/toolchain` restores the cached tools and runs `./x toolchain install <target>` (the cache key follows `tools/toolchain.env`; a target that needs the compilers and has no cache of its own starts from the cache of the compilers). Every workflow uses it instead of repeating the cache and install steps, and a job that needs the result of an earlier job takes it as an artifact.

Actions are pinned by version tag, to versions that run on Node.js 24 (`actions/checkout` v6, `actions/setup-python` v6, `actions/cache` v5, `actions/upload-artifact` v6, `actions/download-artifact` v7).
