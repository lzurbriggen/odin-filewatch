package main

import dirwatch ".."
import "core:log"
import "core:os/os2"
import "core:sync/chan"
import "core:testing"
import "core:time"

Msg :: dirwatch.Msg

@(test)
recursive :: proc(t: ^testing.T) {
	w, err := dirwatch.create(10)
	if err != nil {assert(err == nil)}
	defer dirwatch.destroy(&w)

	rm_dir(t, "tmp")
	make_dir(t, "tmp")
	dirwatch.watch_dir(&w, "tmp", recursive = true)

	cud_file(t, "tmp/test.txt")
	make_dir(t, "tmp/inner")
	cud_file(t, "tmp/inner/bar")

	time.sleep(time.Millisecond)
	changes := [?]Maybe(Msg) {
		Msg{target = .File, event = dirwatch.Ev_Created{path = "test.txt"}},
		Msg{target = .File, event = dirwatch.Ev_Modified{path = "test.txt"}},
		Msg{target = .File, event = dirwatch.Ev_Removed{path = "test.txt"}},
		Msg{target = .Dir, event = dirwatch.Ev_Created{path = "inner"}},
		Msg{target = .File, event = dirwatch.Ev_Created{path = "inner/bar"}},
		Msg{target = .File, event = dirwatch.Ev_Modified{path = "inner/bar"}},
		Msg{target = .File, event = dirwatch.Ev_Removed{path = "inner/bar"}},
		nil,
	}
	receive_and_compare(t, w.chan, changes)
}

@(test)
non_recursive :: proc(t: ^testing.T) {
	w, err := dirwatch.create(10)
	if err != nil {assert(err == nil)}
	defer dirwatch.destroy(&w)

	rm_dir(t, "tmp_nr")
	make_dir(t, "tmp_nr")
	dirwatch.watch_dir(&w, "tmp_nr")

	cud_file(t, "tmp_nr/test.txt")
	make_dir(t, "tmp_nr/inner")
	cud_file(t, "tmp_nr/inner/bar")

	time.sleep(time.Millisecond)
	changes := [?]Maybe(Msg) {
		Msg{target = .File, event = dirwatch.Ev_Created{path = "test.txt"}},
		Msg{target = .File, event = dirwatch.Ev_Modified{path = "test.txt"}},
		Msg{target = .File, event = dirwatch.Ev_Removed{path = "test.txt"}},
		Msg{target = .Dir, event = dirwatch.Ev_Created{path = "inner"}},
		nil,
	}
	receive_and_compare(t, w.chan, changes)
}


main :: proc() {
	context.logger = log.create_console_logger(
		opt = {.Level, .Terminal_Color, .Short_File_Path, .Line},
	)

	w, err := dirwatch.create(10)
	if err != nil {panic("")}
	defer dirwatch.destroy(&w)

	path := "./"
	dirwatch.watch_dir(&w, path, recursive = true)

	for {
		if chan.is_closed(w.chan) {
			break
		}
		if data, ok := chan.try_recv(w.chan); ok {
			log.info("Event received:", data)
		}
	}
}

receive_and_compare :: proc(
	t: ^testing.T,
	ch: chan.Chan(Msg),
	expected: [$N]Maybe(Msg),
	loc := #caller_location,
) {
	msgs := [N]Maybe(Msg){}
	for i in 0 ..< N {
		if chan.is_closed(ch) {
			break
		}
		if data, ok := chan.try_recv(ch); ok {
			msgs[i] = data
			log.debug("Event received:", data)
		}
	}
	for msg, i in msgs {
		testing.expect_value(t, msg, expected[i], loc)
	}
}

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

