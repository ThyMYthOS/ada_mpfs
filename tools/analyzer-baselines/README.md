# adalang_analyzer baselines

Fingerprints of the static-analysis findings that were present when each baseline was written.
`./x analyze` filters them out, so it reports only what is **new**: a tripwire on regressions, not a
claim that the code is clean.

- `<name>.baseline`: the defect rule set (`./x analyze`): `--recommended` plus the ten checks in
  `ANALYZE_EXTRA_CHECKS` of `tools/analyze.sh`.
- `<name>.style.baseline`: the readability rule set (`./x analyze --style`), the checks in
  `ANALYZE_STYLE_CHECKS`. The two sets enable different checks, so neither baseline can stand in for
  the other.
- `<name>` is a row of `tools/analyze.list`.

A project without a baseline fails, even if it has no findings: the baseline is what says it was
analysed. Write or rewrite them with the pinned adalang_analyzer (`./x toolchain install`):

    ./x analyze --update-baseline
    ./x analyze --style --update-baseline

A baselined finding is not a known bug, and a new one is triaged on its merits; re-baseline only when it
is noise.
