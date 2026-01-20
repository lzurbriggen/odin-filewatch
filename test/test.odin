package main

import filewatch ".."
import "core:log"
import "core:os/os2"
import "core:sync/chan"
import "core:testing"

make_dir :: proc(dir: string) {
	err := os2.remove_all(dir)
	if err != nil {assert(err == nil)}
	err = os2.make_directory(dir)
	if err != nil {assert(err == nil)}
}
cud_file :: proc(path: string) {
	f, err := os2.create(path)
	if err != nil {assert(err == nil)}
	os2.flush(f)
	_, err = os2.write_string(f, "foo")
	if err != nil {assert(err == nil)}
	err = os2.flush(f)
	if err != nil {assert(err == nil)}
	err = os2.close(f)
	if err != nil {assert(err == nil)}
	err = os2.remove(path)
	if err != nil {assert(err == nil)}
}

@(test)
recursive :: proc(t: ^testing.T) {
	w, err := filewatch.create(10)
	if err != nil {assert(err == nil)}
	defer filewatch.destroy(&w)

	{
		make_dir("tmp")
		filewatch.watch_dir(&w, "tmp", recursive = true)

		cud_file("tmp/test.txt")
		make_dir("tmp/inner")
		cud_file("tmp/inner/bar")

		changes := [?]filewatch.Msg {
			filewatch.File_Created{path = "test.txt"},
			filewatch.File_Modified{path = "test.txt"},
			filewatch.File_Removed{path = "test.txt"},
			filewatch.File_Created{path = "inner"},
			filewatch.File_Created{path = "inner/bar"},
			filewatch.File_Modified{path = "inner/bar"},
			filewatch.File_Removed{path = "inner/bar"},
		}
		s := 0
		msgs := [len(changes)]filewatch.Msg{}
		for i in 0 ..< len(changes) {
			if chan.is_closed(w.chan) {
				break
			}
			if data, ok := chan.recv(w.chan); ok {
				msgs[i] = data
				s += 1
				log.info("Event received:", data)
			}
		}
		testing.expect_value(t, len(msgs), len(changes))
		for msg, i in changes {
			testing.expect_value(t, msgs[i], msg)
		}
	}
}

@(test)
non_recursive :: proc(t: ^testing.T) {
	w, err := filewatch.create(10)
	if err != nil {assert(err == nil)}
	defer filewatch.destroy(&w)

	{
		make_dir("tmp_nr")
		filewatch.watch_dir(&w, "tmp_nr")

		cud_file("tmp_nr/test.txt")
		make_dir("tmp_nr/inner")
		cud_file("tmp_nr/inner/bar")

		changes := [?]filewatch.Msg {
			filewatch.File_Created{path = "test.txt"},
			filewatch.File_Modified{path = "test.txt"},
			filewatch.File_Removed{path = "test.txt"},
			filewatch.File_Created{path = "inner"},
			// TODO: non-recursive not working
			filewatch.File_Created{path = "inner2"},
		}
		s := 0
		msgs := [len(changes)]filewatch.Msg{}
		for i in 0 ..< len(changes) {
			if chan.is_closed(w.chan) {
				break
			}
			if data, ok := chan.recv(w.chan); ok {
				msgs[i] = data
				s += 1
				log.info("Event received:", data)
			}
		}
		testing.expect_value(t, len(msgs), len(changes))
		for msg, i in changes {
			testing.expect_value(t, msgs[i], msg)
		}
	}
}

main :: proc() {
	w, err := filewatch.create(10)
	if err != nil {panic("")}
	defer filewatch.destroy(&w)

	context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})

	filewatch.watch_dir(&w, "./", recursive = true)

	log.debug("Watching dir...")

	for {
		if chan.is_closed(w.chan) {
			break
		}
		if data, ok := chan.try_recv(w.chan); ok {
			log.info("Event received:", data)
		}
	}
}

