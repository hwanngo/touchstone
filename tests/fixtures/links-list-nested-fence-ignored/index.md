# List-nested fence fixture

A fenced block indented to a list item's content column is still a fence, not an indented
code block, so the link inside it is sample markdown and must not be checked. Restricting
fence markers to columns 0-3 to fix the indented-code-block case would break this.

1. Step one, showing some markdown:

    ```markdown
[bad](does-not-exist.md)
    ```

2. Step two. No other links exist in this file.
