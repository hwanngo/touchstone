# Known-good fixture

This tree is the control: every link here is genuinely valid, so the gate
must pass with **zero** broken links reported. If this fixture and a
defect fixture ever produce the same verdict, the harness is broken, not
the gate.

- Plain relative link: [Other](other.md)
- Cross-file anchor into a real heading: [Other's second section](other.md#section-two)
- Same-file anchor into a real heading below: [Local Heading](#local-heading)
- External link (must be skipped, not resolved as a file): [External](https://example.com/http-not-a-relative-path)
- Mailto link (must be skipped): [Mail](mailto:test@example.com)
- Title-suffixed link at a real file: [Titled](other.md "Some Title")
- A real file whose name contains a literal space: [Spaced file](my file.md)
- Reference-style link: [ref link][ref]

[ref]: other.md "Reference title"

## Local Heading

Body text for the same-file anchor case above.
