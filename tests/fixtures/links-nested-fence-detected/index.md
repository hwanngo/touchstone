# Nested fence marker fixture

Exactly one defect: the broken link in the last paragraph. The `~~~` line below sits
*inside* a backtick fence, where it is sample text rather than a fence of its own. A
shared fence toggle treats it as a closing marker, loses fence state, and silently
drops every line after it — including that broken link — while still exiting 0.

```text
~~~
```

This paragraph is after the fence and links to [gone](really-missing.md).
