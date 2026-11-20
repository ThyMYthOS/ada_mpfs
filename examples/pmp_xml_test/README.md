# pmp_xml_test

The PMP of the hart that runs it holds what the MSS Configurator XML sets for that hart. The values of the
XML are the package `Pmp_Xml` in `src/generated/pmp_xml.ads`, generated from the XML of the Icicle Kit
(`config/boards/icicle`) by the configuration generator; it is never edited by hand:

    python3 config/gen/mpfs_gen pmp --ada examples/pmp_xml_test/src/generated/pmp_xml.ads \
      config/boards/icicle/ICICLE_MSS_mss_cfg.xml

The test reads the PMP CSRs before anything else and prints them, one `at start hart <n>` line each (what
power-on, a reset or a boot stage leaves; reported, not checked: on the Icicle Kit they are not zero after a
power cycle). Unless an entry is locked already, it counts the entries, measures the width of `pmpaddr` (all
ones written to `pmpaddr0` and read back; the lines `pmpaddr0 after writing all ones` and `pmpaddr width`) and
the granularity G, and writes the values of the XML as Microchip's `pmp_configure()` does. Then it compares
`pmpcfg0`, `pmpcfg2` and `pmpaddr0` to `15` with the XML as the hart must return them (the WARL rules of
`Pmp_Csr`, `pmpaddr` in the bits the hart implements), and checks that the XML uses no entry the hart does not
have. It reports `pmp_xml_test_e51`, `pmp_xml_test_u54` (hart 1) or `pmp_xml_test_u54h<N>` (harts 2 to 4,
`--harts N`). With the XML of the Icicle Kit a U54 ends
with entry 0 locked: only a reset undoes it.

`PMP_XML=<file>` takes another XML: `build.sh` generates its table into `obj-<hart>/pmp_xml` and builds with
that one (the generator needs the merged SVD).

    ./x build pmp_xml_test [--hart u54]
    PMP_XML=path/to/my_mss_cfg.xml ./x build pmp_xml_test --hart u54
    ./x qemu pmp_xml_test [--hart 1|2|3|4]

It is built like `bare_hello`, with `Pmp_Csr` and `pmp_mask.S` of `pmp_probe`. What it covers, the emulators
and the commands for the board: [`docs/assurance/pmp-tests.md`](../../docs/assurance/pmp-tests.md).
