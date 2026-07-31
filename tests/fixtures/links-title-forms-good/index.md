# Link title forms

Exactly one thing that must NOT be flagged: every destination below is the same real
file, `other.md`, carrying a title in each of the three CommonMark forms plus the
angle-bracket destination form. Stripping only the double-quoted form leaves the title
attached, the existence test then fails, and every other form is reported falsely broken.

- Double-quoted title: [a](other.md "Some Title")
- Single-quoted title: [b](other.md 'Some Title')
- Parenthesised title: [c](other.md (Some Title))
- Angle-bracket destination: [d](<other.md>)

[e]: other.md 'Single-quoted ref title'
[f]: other.md (Parenthesised ref title)
[g]: <other.md>
