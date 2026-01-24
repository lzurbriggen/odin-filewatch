package glob

import "core:log"
import "core:unicode"
import "core:unicode/utf8"

Glob :: struct {
	compiled: []Glob_Token,
}

Glob_Token :: union {
	Tok_Lit,
	Tok_Slash,
	Tok_Globstar,
	Tok_Any_Text,
	Tok_Any_Char,
	Tok_Range,
	Tok_Or,
	Tok_Neg,
}

Tok_Lit :: string
Tok_Slash :: struct {}
Tok_Globstar :: struct {}
Tok_Any_Text :: struct {}
Tok_Any_Char :: struct {}
Tok_Range :: struct {
	// TODO
}
Tok_Or :: distinct []Glob_Token
Tok_Neg :: struct {}

Err :: enum {
	No_Closing_Brace,
	No_Closing_Bracket,
}

glob_from_pattern :: proc(pat: string) -> (glob: Glob, glob_err: Err) {
	parser := Parser {
		runes = utf8.string_to_runes(pat),
		ast   = make([dynamic]Glob_Token),
	}
	p := &parser

	for {
		tok := scan(p) or_break
		log.debug(tok)
		append(&p.ast, tok)
	}
	glob = Glob {
		compiled = p.ast[:],
	}
	return
}

@(private)
Parser :: struct {
	pos:   int,
	curr:  rune,
	runes: []rune,
	ast:   [dynamic]Glob_Token,
}

@(private)
scan :: proc(p: ^Parser) -> (tok: Glob_Token, tok_ok: bool) {
	r, ok := curr(p)
	if !ok {
		return
	}
	switch r {
	case '/':
		adv(p)
		return Tok_Slash{}, true
	case '*':
		adv(p)
		if nr, ok := curr(p); ok && nr == '*' {
			adv(p)
			return Tok_Globstar{}, ok
		}
		return Tok_Any_Text{}, true
	case '{':
		grp := make([dynamic]Glob_Token)
		adv(p)
		for {
			inner_tok, ok := scan(p)
			if !ok {
				// TODO: err
				return
			}
			append(&grp, inner_tok)
			if r, ok := curr(p); ok {
				if r == '}' {
					adv(p)
					return Tok_Or(grp[:]), true
				}
			}
		}
	// TODO: err
	case '[':
		adv(p)
	case '?':
		adv(p)
		return Tok_Any_Char{}, ok
	case '!':
	case:
		return scan_lit(p), true
	}
	return
}

@(private)
scan_lit :: proc(p: ^Parser) -> Tok_Lit {
	escaping := false
	r, ok := curr(p)
	if !ok {
		return ""
	}
	runes := make([dynamic]rune, context.temp_allocator)
	loop: for {
		if !escaping {
			switch r {
			case '/', '*', '{', '}', '[', ']', '?':
				break loop
			}
		}
		if !escaping && r == '\\' {
			escaping = true
		} else {
			append(&runes, r)
			escaping = false
		}
		r = adv(p) or_break
	}
	return utf8.runes_to_string(runes[:])
}

@(private)
curr :: proc(p: ^Parser, idx: Maybe(int) = nil) -> (r: rune, ok: bool) #optional_ok {
	pos := idx.(int) or_else p.pos
	for pos >= len(p.runes) {
		return
	}
	return p.runes[pos], true
}
@(private)
adv :: proc(p: ^Parser, n := 1) -> (r: rune, ok: bool) #optional_ok {
	p.pos += n
	return curr(p)
}
@(private)
next :: proc(p: ^Parser) -> (r: rune, ok: bool) #optional_ok {
	return curr(p, p.pos + 1)
}

@(private)
is_letter :: proc(r: rune) -> bool {
	if r < utf8.RUNE_SELF {
		switch r {
		case '_':
			return true
		case 'A' ..= 'Z', 'a' ..= 'z':
			return true
		}
	}
	return unicode.is_letter(r)
}

@(private)
is_digit :: proc(r: rune) -> bool {
	if '0' <= r && r <= '9' {
		return true
	}
	return unicode.is_digit(r)
}
// @(private)
// read_

