# Component

Mirrors the real docs that a fence-blind scaffolding rule would flag: the closing `script` tag
in the Vue/Svelte/Nuxt examples, and the landmark elements in practices/accessibility.md. Both
sit on their own line at column zero, inside a fence, and are legitimate content.

## 1. Single-file component

The tilde line inside the block below is example text, not a fence: a rule that shared one
toggle between the two markers would treat it as a close, and every line after it — including
the closing script tag — as prose.

```svelte
<script lang="ts">
  let count = 0;
~~~ this tilde line is inside the backtick block, not a fence marker
</script>
```

## 2. Landmarks

```html
<main>
  <h1>Title</h1>
</main>
```

## Definition of done

- [ ] The rule above is enforced by a gate
