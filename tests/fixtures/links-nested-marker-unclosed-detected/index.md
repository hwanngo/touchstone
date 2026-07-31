# Unclosed fence containing a nested marker

Exactly one defect: the backtick fence opened below is never closed, so the rest of the file
is dropped before parsing. The `~~~` line inside it is sample text rather than a fence of its
own. A shared fence toggle treats it as the closing marker, concludes the file is balanced,
and reports nothing at all — the whole tail of the file silently unexamined, gate exit 0.

```text
~~~
This line is still inside the never-closed backtick fence.
