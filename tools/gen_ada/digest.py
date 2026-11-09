# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""SHA-256 of files and of trees of generated files.

  file_digest(path)               the hash of one file (svd/PolarfireSoC.sha256)
  tree_digest(directory, pattern) the hash of the files of a directory (libs/mpfs_pac/MPFS_Registers.sha256)

Both are hex strings. The shell side has the same for the cache keys of the runtime
(`mpfs_sha`, `mpfs_tree_hash` in tools/mpfs-env.sh).
"""
import hashlib
from pathlib import Path

from .errors import GenError


def file_digest(path: Path) -> str:
    """SHA-256 of the bytes of <path> as a hex string."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(directory: Path, pattern: str = "*.ads", *, error: type[GenError] = GenError) -> str:
    """SHA-256 over the files of <directory> that match <pattern>, in name order, each as name, NUL,
    content, NUL.

    Names and contents count, the order in which the files were made does not. A directory without a
    matching file raises `error` (the exception class of the calling generator, so that it reports the
    problem with its own exit status).
    """
    files = sorted(directory.glob(pattern))
    if not files:
        raise error(f"no {pattern} file in {directory}")
    h = hashlib.sha256()
    for path in files:
        h.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    return h.hexdigest()
