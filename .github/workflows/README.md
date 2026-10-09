# `.github/workflows/`

- **Purpose:** GitHub Actions workflows (logic lives in `./x`).

| Workflow | Content |
|---|---|
| `svd.yml` | Job `svd`: Python 3.13 with the packages of `tools/requirements.txt`, `xmllint` and the svdtools version pinned in `tools/toolchain.env` (installed with `./x toolchain install svdtools`, cached by the pin), then `./x svd check`, `tests/host/svd/run.sh` and `tests/host/x/run.sh`. Runs on pull requests that touch the SVD, its tools or the host tests, and on pushes to `main`. |

Actions are pinned by version tag.
