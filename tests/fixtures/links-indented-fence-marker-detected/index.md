# Indented code block containing a fence marker

Exactly one defect: the broken link in the final paragraph. The four-space indented block
below is an indented code block whose body happens to show a literal fence opener. Reading
that opener as a real fence produces a false UNCLOSED-FENCE and drops the rest of the file
from the scan, hiding the defect that is actually there.

    ```bash

That was sample text inside an indented code block, not a fence.

Now the real defect: [gone](really-missing.md).
