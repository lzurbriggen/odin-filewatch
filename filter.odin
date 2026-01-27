package dirwatch

import "glob"

Filter :: struct {
	events: [Target]Event_Filter,
	globs:  []glob.Pattern,
}

Event_Filter_Flags :: enum {
	Create,
	Modify,
	Delete,
	Move,
}
Event_Filter :: bit_set[Event_Filter_Flags]

asdf :: proc() {
	glob.match("/foo/**/bar{.txt,.md}", "/foo/odin/bar.md")
	pattern, err := glob.pattern_from_string("/foo/**/bar{.txt,.md}")
	defer glob.pattern_destroy(&pattern)
	glob.match(pattern, "/foo/odin/bar.md")
	// glob.match_from_pattern("/foo/**/bar{.txt,.md}", "/foo/odin/bar.md")
}

