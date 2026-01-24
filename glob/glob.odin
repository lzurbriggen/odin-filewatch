package glob

import "core:log"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Glob_Prepared :: struct {
	toks: []Glob_Token,
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

glob_from_pattern :: proc(pat: string) -> (glob: Glob_Prepared, glob_err: Err) {
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
	glob = Glob_Prepared {
		toks = p.ast[:],
	}
	return
}

glob :: proc {
	glob_str,
	glob_prepared,
}

glob_str :: proc(pattern: string, input: string) -> bool {
	prep, err := glob_from_pattern(pattern)
	if err != nil {
		return false
	}
	return glob_prepared(prep, input)
}
glob_prepared :: proc(prepared: Glob_Prepared, input: string) -> bool {
	runes := utf8.string_to_runes(input)
	defer delete(runes)
	return _glob_toks(prepared.toks, runes)
}
_glob_toks :: proc(prepared: []Glob_Token, runes: []rune) -> (matched: bool) {
	pos := 0
	for tok, tok_i in prepared {
		log.info("rem", runes[pos:], tok, pos)
		if pos >= len(runes) {return}

		switch t in tok {
		case Tok_Slash:
			r := runes[pos]
			if r != '/' && r != '\\' {return}
			pos += 1
		case Tok_Globstar:
			last_off := 0
			for r, i in runes[pos:] {
				if r == '/' || r == '\\' {
					last_off = i
					// TODO: are there better solutions than this full eval?
					if _glob_toks(prepared[tok_i + 1:], runes[pos + last_off:]) {
						return true
					}
				}
			}
			pos = last_off + pos

		case Tok_Any_Text:
			for r, i in runes[pos:] {
				if r == '/' || r == '\\' {
					break
				}
				pos += 1
			}

		case Tok_Any_Char:
			r := runes[pos]
			if r == '/' || r == '\\' {return}
			pos += 1

		case Tok_Lit:
			off := 0
			for r, i in t {
				if r != runes[pos + i] {return}
				off += 1
			}
			pos += off

		case Tok_Range:

		case Tok_Or:
			// TODO: incomplete
			if !_glob_toks(cast([]Glob_Token)t, runes[pos:]) {return}

		case Tok_Neg:
		}
	}
	return true
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

