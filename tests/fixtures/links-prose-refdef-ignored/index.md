# Prose that looks like a reference definition

Exactly one thing that must NOT be flagged. The line below opens with `[Label]:` but
its remainder is a sentence, not a single-token destination, so CommonMark leaves it as
an ordinary paragraph. A definition parser that takes the whole remainder as a target
reports a broken link to a file named "remember to update the changelog before release."

[Note]: remember to update the changelog before release.
