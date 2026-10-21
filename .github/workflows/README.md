# `.github/workflows/`

- **Purpose:** GitHub Actions workflows (logic lives in `./x`).

| Workflow | Content |
|---|---|
| `registers.yml` | Job `svd`: Python 3.13 with the packages of `tools/requirements.txt`, `xmllint` and the pinned svdtools (`toolchain` action, target `svdtools`), then `./x svd check`, `tests/host/svd/run.sh` and `tests/host/x/run.sh`; it keeps the merged SVD as the artifact `svd`. Job `pac` (after `svd`): takes that artifact instead of merging again, the pinned GNAT, gprbuild, alr, svdtools and svd2ada (target `pac`, which skips gnatprove and adalang_analyzer), then `tests/host/pac/run.sh` and `./x pac check`. Runs on a push to any branch and on a pull request against `main` that touch the SVD, the PAC, its tools or the host tests. |
| `pac-regenerate.yml` | Regenerates `libs/mpfs_pac/src/generated` with the pinned svd2ada and commits the result to the pull request branch. Runs on request and when the workflow or an action changes. |

The composite action `.github/actions/toolchain` restores the cached tools and runs `./x toolchain install <target>` (the cache key follows `tools/toolchain.env`; a target without a cache of its own starts from the cache of the compilers). Every workflow uses it instead of repeating the cache and install steps, and a job that needs the result of an earlier job takes it as an artifact.

Actions are pinned by version tag, to versions that run on Node.js 24 (`actions/checkout` v6, `actions/setup-python` v6, `actions/cache` v5, `actions/upload-artifact` v6, `actions/download-artifact` v7).
