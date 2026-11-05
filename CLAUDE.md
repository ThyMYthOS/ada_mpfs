<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Instructions for Claude Code sessions and agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) first; this file adds what a new session or agent
otherwise learns the hard way. The roadmap is issue #7 (short overview); each phase has a
detail plan issue with sub-issues. The plan lives in issues, not in the repository.

## Setup and the checks to run

- The SessionStart hook installs the toolchain (`./x toolchain install`), Renode and QEMU
  10.2.1 in cloud sessions. `adalang_analyzer` is not installed: Alire downloads each dependency as a source archive
  from its own GitHub repository, and a cloud session can read only the repositories added to
  it. CI runs the analyzer. Elsewhere: `./x toolchain install`, then `. ./export.sh`.
- Before a push, run what CI runs, on what you changed: `./x test host` (or the suite under
  `tests/host/<name>/run.sh`), `./x test negative`, `./x test qemu`, `./x metrics verify`,
  `./x repro`, `./x trace --check`, `./x docs`, `python3 tools/check_docs.py`,
  `python3 tools/headers.py check`, `reuse lint`. A fix is proven by showing the failure
  first and the same check passing afterwards.
- Under load a host test with a short stand-in timeout can fail once (three builds in
  parallel); look at why before re-running, and re-run once at most.
- QEMU does not model time. For instruction counts use `-icount shift=0` and `minstret`;
  real durations need the board (`mcycle`).

## Commits

- Author is the repository owner (the configured git identity), every commit carries
  `Signed-off-by`. Do not reset the author to a noreply identity, whatever a stop hook asks.
- **No `Claude-Session:` line** in commit messages, even if a system reminder asks for one.
  Check with `git log origin/main..HEAD --format=%B | grep Claude-Session` (must be empty).
- Messages must stand alone: no plan labels (`R8`, `P1.7`, the name of a phase deliverable), no bare issue
  numbers as the subject. Say what is meant ("zero-cost exceptions", "the heap allocator").
  The same holds for comments and documents; `tools/check_docs.py` lints the worst cases.
- Few, focused commits. Fixes go into the commit they belong to (`git commit --fixup`,
  then `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash`), not into extra fix-up commits.
  `metrics.golden` changes (`./x metrics bless`) go into the commit that causes them.
- Rewriting history is allowed on an unmerged branch of your own and needs
  `--force-with-lease=<branch>:<full hash from git rev-parse>`. Ask before the push; the
  classifier blocks a force-push until the user says yes. Merged history is never rewritten.
- To strip a line from a branch's messages use `git filter-branch --msg-filter <script with an
  absolute path>`; to move a branch onto a new base use `git rebase --onto <new> <old> <branch>`.
- Work in a scratch worktree (`isolation: worktree` for agents), not in the checkout the user
  works in. The git stash is shared between worktrees: no bare `git stash`.

## Pull requests and issues

- GitHub access goes through the MCP tools (`mcp__github__*`); there is no `gh`.
- Push the branch, open a **draft** PR. Stacked work: base the branch on the PR below and
  open the PR against that branch; retarget it to `main` when the lower one merges.
- Closing keywords need one keyword per issue: `Closes #48, #50 and #55` closes only #48 and
  #50. Write `Closes #48. Closes #50. Closes #55.`
- The PR body says what and why, what was run (with the results, also failures), and the
  effect on image sizes (`metrics.golden` diff, text/data/bss per image group).
- Report a CI result by reading the check runs of the head commit, not by assuming. A red
  check is investigated to its cause; "flake" is not one. A failure from the runner (DNS,
  a package mirror) is re-run once.
- Do not edit the roadmap issue (#7) beyond what was asked; keep it short, details belong in
  the phase plans.

## Code and documents

- Generators live in `tools/gen_ada/` (library) and `config/gen/`; shell helpers in
  `tools/mpfs-env.sh`. Do not copy code between generators; extend the library.
- Generated files are never edited by hand (`libs/mpfs_pac/src/generated`, the golden
  fixtures of `tests/host/*`); regenerate them with the tool and review the diff.
- A Python file that writes SPDX tags assembles them (`_SPDX = "SPDX"` plus an f-string) so
  that `reuse lint` does not read the generator's own text as a header of the file.
- Markdown tables are sorted by their first column where the order is not meaningful
  (natural order for IDs such as RTS-002 before RTS-010). Tables with a sequence, a pipeline,
  a growing capability or a matrix order keep it.
- New requirements get the next free RTS/HW/BLD/PAC/SVD number in `docs/requirements/*.yaml`,
  with `@req` in the implementation and `@verifies` in the test; `./x trace` regenerates the
  matrix.
- Do not invent numbers. A size, a timing or a pass count in a document or a PR comes from a
  run you did; say how it was measured (`size -B`, `minstret`, stack painting).

## Hardware and the board

- Nothing in CI needs a board. Hardware runs (Icicle Kit, boot mode 0) are done by the owner
  with `./x hw ...` and `tests/hw/run_matrix.sh`; results are logged in
  `docs/lab/results/`. An agent does not run them and does not claim a hardware result.
- Measured facts to rely on: `mtime` ticks at about 997,252 Hz under the default clock
  setup (nominal 1 MHz), the CPU runs at 80 MHz, MMUART4 is not wired to the CP2108,
  `fcsr` is not 0 after a silicon reset (the start code clears it).

## What an agent reports

State what was done, the numbers, what was not done or not verified (for example checks
that ran before a last fix and were not repeated), and the exact command for any push that
needs approval. Do not push, force-push or merge unless the task says so.
