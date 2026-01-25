package glob

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os/os2"
import "core:path/filepath"

Opts :: struct {
	pattern: string `args:"pos=0,required" usage:"/my/glob/**/pattern.txt"`,
}

main :: proc() {
	context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	opts: Opts
	err := flags.parse(&opts, os2.args[1:])
	if err != nil {
		log.error(err)
		return
	}

	{
		pat_str := opts.pattern
		log.debug("Pattern:", pat_str)
		pat, err := pattern_from_string(pat_str)
		if err != nil {
			log.error("Error in pattern:", err)
			return
		}
		defer pattern_destroy(&pat)

		cwd, _ := os2.get_working_directory(context.allocator)
		defer delete(cwd)
		log.debug("CWD:", cwd)

		walker := os2.walker_create(cwd)
		defer os2.walker_destroy(&walker)
		for fi in os2.walker_walk(&walker) {
			path_rel, _ := filepath.rel(cwd, fi.fullpath)
			if match(pat, path_rel) {
				fmt.println(path_rel)
			}
		}
	}
}

