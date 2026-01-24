package glob

import "core:log"
import "core:testing"

@(test)
parse_test :: proc(t: ^testing.T) {
	expect_match(t, glob_from_pattern(""), {})
	expect_match(t, glob_from_pattern("/"), {Tok_Slash{}})
	expect_match(t, glob_from_pattern("foo/bar"), {"foo", Tok_Slash{}, "bar"})
	expect_match(
		t,
		glob_from_pattern("foo/*/*.bar"),
		{"foo", Tok_Slash{}, Tok_Any_Text{}, Tok_Slash{}, Tok_Any_Text{}, ".bar"},
	)
	expect_match(
		t,
		glob_from_pattern("foo/**/bar"),
		{"foo", Tok_Slash{}, Tok_Globstar{}, Tok_Slash{}, "bar"},
	)
	expect_match(t, glob_from_pattern("foo/?.bar"), {"foo", Tok_Slash{}, Tok_Any_Char{}, ".bar"})

	expect_match(t, glob_from_pattern("{foo,bar}"), {Tok_Or{{"foo"}, {"bar"}}})
	expect_match(
		t,
		glob_from_pattern("{**/bin,bin}"),
		{Tok_Or{{Tok_Globstar{}, Tok_Slash{}, "bin"}, {"bin"}}},
	)
}

@(test)
match_test :: proc(t: ^testing.T) {
	testing.expect_value(t, match("/**/bin", "/foo/bar/bin"), true)
	testing.expect_value(t, match("/**/bin", "/foo/bar/hellope"), false)
	testing.expect_value(t, match("/**/bin", "//bin"), true)
	testing.expect_value(t, match("/**/bin", "/bin"), false)
	// TODO: fix
	testing.expect_value(t, match("**/bin", "/bin"), true)
	testing.expect_value(t, match("*/bin", "/bin"), true)
	testing.expect_value(t, match("*/bin", "bin"), false)
	testing.expect_value(t, match("*/bin", "foo/bin"), true)
	testing.expect_value(t, match("/*/bin", "/bin"), false)
	testing.expect_value(t, match("/*/bin", "/foo/bin"), true)
	testing.expect_value(t, match("/*/bin", "/foo/bar/bin"), false)
	testing.expect_value(t, match("test/*/hellope", "test/bar/hellope"), true)
	testing.expect_value(t, match("/**/test/*/hellope", "/foo/test/bar/hellope"), true)
	testing.expect_value(t, match("?at", "cat"), true)
	testing.expect_value(t, match("?at", "bat"), true)
	testing.expect_value(t, match("?at", ".at"), true)
	testing.expect_value(t, match("?at", ".ar"), false)
	testing.expect_value(t, match("?at", "/at"), false)

	testing.expect_value(t, match("{b,r}", "bat"), true)
	testing.expect_value(t, match("{b,r}", "rat"), true)
	testing.expect_value(t, match("{b,r}", "fat"), false)

	testing.expect_value(t, match("**/foo/{**/bin,bin}", "bar/foo/test/2/bin"), true)
	testing.expect_value(t, match("**/foo/{**/bin,?bar}", "bar/foo/8bar"), true)
}

@(private)
expect_match :: proc(
	t: ^testing.T,
	glob: Glob_Prepared,
	err: Err,
	expected: []Glob_Token,
	loc := #caller_location,
) {
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(glob.toks), len(expected), loc)
	for tok, i in expected {
		tok_match(t, glob.toks[i], tok, loc)
	}
}

// TODO: easier way to do this?
@(private)
tok_match :: proc(t: ^testing.T, a, b: Glob_Token, loc := #caller_location) {
	switch a in a {
	case Tok_Or:
		b, ok := b.(Tok_Or)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, len(a), len(b), loc)
		for grp, grp_i in a {
			for tok, i in grp {
				tok_match(t, a[grp_i][i], tok, loc)
			}
		}
	case Tok_Range:
	// TODO
	case Tok_Any_Char:
		b, ok := b.(Tok_Any_Char)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	case Tok_Any_Text:
		b, ok := b.(Tok_Any_Text)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	case Tok_Globstar:
		b, ok := b.(Tok_Globstar)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	case Tok_Lit:
		b, ok := b.(Tok_Lit)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	case Tok_Neg:
		b, ok := b.(Tok_Neg)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	case Tok_Slash:
		b, ok := b.(Tok_Slash)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	}
}

