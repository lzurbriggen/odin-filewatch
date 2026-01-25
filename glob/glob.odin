package glob

import "core:log"
import "core:mem/virtual"
import "core:unicode/utf8"

Pattern :: struct {
	arena: virtual.Arena,
	toks:  []Glob_Token,
}

Glob_Token :: union {
	Tok_Symbol,
	Tok_Lit,
	Tok_Range,
	Tok_Or,
}

Tok_Lit :: string
Tok_Symbol :: enum u8 {
	Slash,
	Globstar,
	Any_Char,
	Any_Text,
	Negate,
}
Tok_Range :: struct {
	a, b: rune,
}
Tok_Or :: distinct [][]Glob_Token

Err :: enum {
	No_Closing_Brace,
	No_Closing_Bracket,
}

pattern_from_string :: proc(pat: string) -> (glob: Pattern, glob_err: Err) {
	err := virtual.arena_init_growing(&glob.arena)
	if err != nil {
		// TODO
		return
	}
	context.allocator = virtual.arena_allocator(&glob.arena)
	parser := Parser {
		runes = utf8.string_to_runes(pat),
		ast   = make([dynamic]Glob_Token),
	}
	p := &parser

	for {
		tok := scan(p) or_break
		append(&p.ast, tok)
	}
	glob.toks = p.ast[:]
	return
}

pattern_destroy :: proc(prep: ^Pattern) {
	virtual.arena_destroy(&prep.arena)
}

match :: proc {
	match_string,
	match_pattern,
}

match_string :: proc(pattern: string, input: string) -> bool {
	prep, err := pattern_from_string(pattern)
	if err != nil {
		return false
	}
	defer pattern_destroy(&prep)
	return match_pattern(prep, input)
}
match_pattern :: proc(prepared: Pattern, input: string) -> bool {
	arena: virtual.Arena
	err := virtual.arena_init_growing(&arena)
	if err != nil {
		// TODO: err
		return false
	}
	alloc := virtual.arena_allocator(&arena)
	defer free_all(alloc)
	context.allocator = alloc
	runes := utf8.string_to_runes(input)
	defer delete(runes)
	_, match_res := _match(prepared.toks, runes)
	return match_res
}

_match :: proc(prepared: []Glob_Token, runes: []rune) -> (end_idx: int, matched: bool) {
	pos := 0
	for tok, tok_i in prepared {
		if pos >= len(runes) {return}

		switch t in tok {
		case Tok_Symbol:
			switch t {
			case .Slash:
				r := runes[pos]
				if r != '/' && r != '\\' {return}
				pos += 1
			case .Globstar:
				last_off := 0
				for r, i in runes[pos:] {
					if r == '/' || r == '\\' {
						last_off = i
						// TODO: are there better solutions than this full eval?
						if end_idx, matched := _match(
							prepared[tok_i + 1:],
							runes[pos + last_off:],
						); matched {
							return end_idx, true
						}
					}
				}
				pos = last_off + pos

			case .Any_Text:
				for r, i in runes[pos:] {
					if r == '/' || r == '\\' {
						break
					}
					// TODO: are there better solutions than this full eval?
					if end_idx, matched := _match(prepared[tok_i + 1:], runes[pos:]); matched {
						return end_idx, true
					}
					pos += 1
				}

			case .Any_Char:
				r := runes[pos]
				if r == '/' || r == '\\' {return}
				pos += 1

			case .Negate:
			}

		case Tok_Lit:
			off := 0
			for r, i in t {
				if r != runes[pos + i] {return}
				off += 1
			}
			pos += off

		case Tok_Range:
			r := runes[pos]
			if r < t.a || r > t.b {return}
			pos += 1

		case Tok_Or:
			for grp in t {
				if matched_pos, matched := _match(cast([]Glob_Token)grp, runes[pos:]); matched {
					return matched_pos, true
				}
			}
			return pos, false

		}
	}
	return pos, true
}

@(private)
Parser :: struct {
	pos:   int,
	curr:  rune,
	runes: []rune,
	ast:   [dynamic]Glob_Token,
}

@(private)
scan :: proc(p: ^Parser, break_on: rune = 0) -> (tok: Glob_Token, tok_ok: bool) {
	r, ok := curr(p)
	if !ok || (break_on != 0 && r == break_on) {
		return
	}
	switch r {
	case '/':
		adv(p)
		return Tok_Symbol.Slash, true
	case '*':
		if nr, ok := adv(p); ok && nr == '*' {
			adv(p)
			return Tok_Symbol.Globstar, ok
		}
		return .Any_Text, true
	case '{':
		grps := make([dynamic][]Glob_Token)
		grp := make([dynamic]Glob_Token)
		adv(p)
		for {
			inner_tok, ok := scan(p, ',')
			if !ok {
				// TODO: err
				log.warn("Failed to read tok")
				return
			}
			append(&grp, inner_tok)
			if r, ok := curr(p); ok {
				if r == ',' {
					adv(p)
					append(&grps, grp[:])
					grp = make([dynamic]Glob_Token)
				}
				if r == '}' {
					adv(p)
					append(&grps, grp[:])
					return Tok_Or(grps[:]), true
				}
			}
		}
	// TODO: err
	case '[':
		escaping := false
		r, ok := adv(p)
		if !ok {
			// TODO: err
			return
		}
		// TODO: alloc
		groups := make([dynamic][]Glob_Token, context.temp_allocator)
		range: Maybe(Tok_Range) = nil
		for {
			if !escaping {
				if r == ']' {
					adv(p)
					return Tok_Or(groups[:]), true
				}
				if next(p) == '-' {
					range = Tok_Range {
						a = r,
					}
					adv(p) or_break
					r = adv(p) or_break
					continue
				}
			}
			if !escaping && r == '\\' {
				escaping = true
			} else {
				slc := make([]Glob_Token, 1)
				if ran, ok := range.(Tok_Range); ok {
					ran.b = r
					slc[0] = ran
				} else {
					slc[0] = utf8.runes_to_string({r})
				}
				append(&groups, slc)
				escaping = false
			}
			r = adv(p) or_break
		}
	// TODO: err
	case '?':
		adv(p)
		return .Any_Char, ok
	case '!':
		adv(p)
		return .Negate, ok
	case:
		return scan_lit(p, break_on), true
	}
	return
}

@(private)
scan_lit :: proc(p: ^Parser, break_on: rune = 0) -> Tok_Lit {
	escaping := false
	r, ok := curr(p)
	if !ok {
		return ""
	}
	// TODO: alloc
	runes := make([dynamic]rune, context.temp_allocator)
	loop: for {
		if !escaping {
			switch r {
			case '/', '*', '{', '}', '[', ']', '?':
				break loop
			case break_on:
				if break_on != 0 {
					break loop
				}
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
next :: proc(p: ^Parser, off := 1) -> (r: rune, ok: bool) #optional_ok {
	return curr(p, p.pos + off)
}

