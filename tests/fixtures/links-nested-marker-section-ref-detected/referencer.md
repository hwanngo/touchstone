# Referencer

Exactly one defect: the section reference in the final paragraph is out of range. The `~~~`
line below sits inside a backtick fence, where it is sample text. A shared fence toggle reads
it as a closing marker, so the real closing marker re-opens a fence instead, the paragraph
below is never scanned, and the out-of-range reference is silently unchecked.

```text
~~~
```

See doc.md §9, which does not exist.
