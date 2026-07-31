---
name: demo-standards
description: Use when editing demo code in a touchstone fixture repo, a deliberately ordinary description that is long enough to clear the forty character minimum.
license: MIT
metadata:
  version: 0.1.0
  author: touchstone
---

# demo standards

Full standard: `standards/design/resilience.md`.

## Always

- Give every outbound call a deadline.
- Copy the template before editing it:

```bash
cp fixture-template.md docs/fixture-output.md
~~~
cat fixture-inside-after-tilde.md
```

- The same example with the other fence marker:

~~~
cat fixture-tilde-fenced.md
~~~

- Retry budgets live in `fixture-after-fence.md`.

## Done

Deadlines set. See `standards/design/resilience.md`.
