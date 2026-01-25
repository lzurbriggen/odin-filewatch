package glob

import "core:log"
import "core:testing"

@(test)
parse_test :: proc(t: ^testing.T) {
	S :: Tok_Symbol

	expect_match(t, pattern_from_string(""), {})
	expect_match(t, pattern_from_string("/"), {S.Slash})
	expect_match(t, pattern_from_string("foo/bar"), {"foo", S.Slash, "bar"})
	expect_match(
		t,
		pattern_from_string("foo/*/*.bar"),
		{"foo", S.Slash, S.Any_Text, S.Slash, S.Any_Text, ".bar"},
	)
	expect_match(
		t,
		pattern_from_string("foo/**/bar"),
		{"foo", S.Slash, S.Globstar, S.Slash, "bar"},
	)
	expect_match(t, pattern_from_string("foo/?.bar"), {"foo", S.Slash, S.Any_Char, ".bar"})

	expect_match(t, pattern_from_string("{foo,bar}"), {Tok_Or{{"foo"}, {"bar"}}})
	expect_match(
		t,
		pattern_from_string("{**/bin,bin}"),
		{Tok_Or{{S.Globstar, S.Slash, "bin"}, {"bin"}}},
	)

	expect_match(
		t,
		pattern_from_string("[ab0-9]"),
		{Tok_Or{{"a"}, {"b"}, {Tok_Range{a = '0', b = '9'}}}},
	)
	expect_match(t, pattern_from_string("[0-9]"), {Tok_Or{{Tok_Range{a = '0', b = '9'}}}})

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

	testing.expect_value(t, match("[abc]", "a"), true)
	testing.expect_value(t, match("[abc]", "b"), true)
	testing.expect_value(t, match("[abc]", "c"), true)
	testing.expect_value(t, match("[abc]", "d"), false)
	testing.expect_value(t, match("[0-9]", "0"), true)
	testing.expect_value(t, match("[0-9]", "9"), true)
	testing.expect_value(t, match("[0-9]", "5"), true)
	testing.expect_value(t, match("[0-9]", "a"), false)
	testing.expect_value(t, match("[a-c]", "a"), true)
	testing.expect_value(t, match("[a-c]", "b"), true)
	testing.expect_value(t, match("[a-c]", "c"), true)
	testing.expect_value(t, match("[a-c]", "d"), false)

	testing.expect_value(t, match("[a-c]", "c"), true)
	testing.expect_value(t, match("[<->]", "<"), true)
	testing.expect_value(t, match("[<->]", "="), true)
	testing.expect_value(t, match("[<->]", ">"), true)
	testing.expect_value(t, match("[<->]", "?"), false)
	testing.expect_value(t, match("[ɐ-ʯ]", "ʧ"), true)
	testing.expect_value(t, match("[ɐ-ʯ]", "ʰ"), false)
	testing.expect_value(t, match("[٠-٩]", "٢"), true)

	testing.expect_value(t, match("/foo/**/[a-zA-Z]elp", "/foo//welp"), true)
	testing.expect_value(t, match("/foo/**/[a-zA-Z]elp", "/foo/bar/Help"), true)
}

@(private)
expect_match :: proc(
	t: ^testing.T,
	glob: Pattern,
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
	case Tok_Symbol:
		b, ok := b.(Tok_Symbol)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	case Tok_Lit:
		b, ok := b.(Tok_Lit)
		testing.expect_value(t, ok, true, loc)
		testing.expect_value(t, a, b, loc)
	}
}

