WIP

Odin library to check if paths match a pattern.

> [!NOTE]
> For personal use. I will look at issues/PRs at my leisure, or not at all.

## Features

- `/` path separators (will match `\` on Windows)
- `?` any single character
- `*` zero or more characters
- `**` zero or more path segments
- `{}` matches when one or more sub-patterns match (e.g. `{*.md,*.txt}`)
- `[]` single character match from selection (e.g. `[ab0-9]` matches `a`, `b` or any digit)
  - use `!` to check if the selection does *not* match (e.g. `[!0-9]`)

## Usage

```odin
import "glob"

// one-off check
glob.match("/foo/**/bar{.txt,.md}", "/foo/odin/bar.md") // true

// parse pattern only once for multiple checks
pattern, err := glob.pattern_from_string("/foo/**/bar{.txt,.md}")
defer glob.pattern_destroy(&pattern)
glob.match(pattern, "/foo/odin/bar.md") // true
glob.match(pattern, "/foo/odin/bar.csv") // false
```

