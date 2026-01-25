wip

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

