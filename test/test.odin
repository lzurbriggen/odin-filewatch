package main

import filewatch ".."
import "core:log"
import "core:os/os2"
import "core:sync/chan"
import "core:testing"

rm_dir :: proc(t: ^testing.T, dir: string) {
	err := os2.remove_all(dir)
	testing.expect_value(t, err, nil)
}

make_dir :: proc(t: ^testing.T, dir: string) {
	err := os2.make_directory(dir)
	testing.expect_value(t, err, nil)
}
cud_file :: proc(t: ^testing.T, path: string) {
	f, err := os2.create(path)
	testing.expect_value(t, err, nil)
	_, err = os2.write_string(f, "foo")
	testing.expect_value(t, err, nil)
	err = os2.flush(f)
	testing.expect_value(t, err, nil)
	err = os2.close(f)
	testing.expect_value(t, err, nil)
	err = os2.remove(path)
	testing.expect_value(t, err, nil)
}

@(test)
recursive :: proc(t: ^testing.T) {
	w, err := filewatch.create(10)
	if err != nil {assert(err == nil)}
	defer filewatch.destroy(&w)

	{
		rm_dir(t, "tmp")
		make_dir(t, "tmp")
		filewatch.watch_dir(&w, "tmp", recursive = true)

		cud_file(t, "tmp/test.txt")
		make_dir(t, "tmp/inner")
		cud_file(t, "tmp/inner/bar")

		changes := [?]filewatch.Msg {
			filewatch.File_Created{path = "test.txt"},
			filewatch.File_Modified{path = "test.txt"},
			filewatch.File_Removed{path = "test.txt"},
			filewatch.File_Created{path = "inner"},
			// TODO: flaky
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

	rm_dir(t, "tmp_nr")
	make_dir(t, "tmp_nr")
	filewatch.watch_dir(&w, "tmp_nr")

	cud_file(t, "tmp_nr/test.txt")
	make_dir(t, "tmp_nr/inner")
	cud_file(t, "tmp_nr/inner/bar")

	changes := [?]filewatch.Msg {
		filewatch.File_Created{path = "test.txt"},
		filewatch.File_Modified{path = "test.txt"},
		filewatch.File_Removed{path = "test.txt"},
		filewatch.File_Created{path = "inner"},
		// TODO: non-recursive not working
		// filewatch.File_Created{path = "inner/bar"},
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

