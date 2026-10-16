# `.github/workflows/`

- **Purpose:** GitHub Actions workflows (logic lives in `./x`).

| Workflow | Content |
|---|---|
| `svd.yml` | Job `svd`: Python 3.13 with the packages of `tools/requirements.txt`, `xmllint` and the svdtools version pinned in `tools/toolchain.env` (installed with `./x toolchain install svdtools`, cached by the pin), then `./x svd check`, `tests/host/svd/run.sh` and `tests/host/x/run.sh`. Runs on a push to any branch and on a pull request against `main` that touch the SVD, its tools or the host tests. |
| `pac.yml` | Job `pac`: the pinned GNAT, gprbuild, alr, svdtools and svd2ada (`./x toolchain install pac`, which skips gnatprove and adalang_analyzer, cached by `tools/toolchain.env`), then `tests/host/pac/run.sh` and `./x pac check`. Runs on a push to any branch and on a pull request against `main` that touch the SVD, the PAC, its tools or the host tests. |

Actions are pinned by version tag, to versions that run on Node.js 24 (`actions/checkout` v6, `actions/setup-python` v6, `actions/cache` v5, `actions/upload-artifact` v6).
