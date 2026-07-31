# Unclosed fence fixture

Exactly one defect: the fence opened below is never closed, so everything after it is
dropped before parsing and the broken link in the final paragraph is never seen.

```text

This paragraph is inside the never-closed fence and links to [gone](really-missing.md).
