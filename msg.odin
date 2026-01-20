package fswatch

import "core:container/queue"
import "core:sync/chan"
import "core:time"

_Msg_Chan :: chan.Chan(Msg)

Msg :: union {
	File_Created,
	File_Modified,
	File_Removed,
	File_Renamed,
}

File_Created :: struct {
	path: string,
}
File_Modified :: struct {
	path: string,
}
File_Removed :: struct {
	path: string,
}
File_Renamed :: struct {
	old_path: string,
	new_path: string,
}

Msg_Buffer :: struct {
	debounce_time: time.Duration,
	messages:      map[Msg]time.Time,
}

_push_message :: proc(buf: ^Msg_Buffer, msg: Msg) {
	buf.messages[msg] = time.now()
}

_tick :: proc(buf: ^Msg_Buffer, msg_queue: ^queue.Queue(Msg)) {
	for msg, last_received_time in buf.messages {
		if time.diff(last_received_time, time.now()) >= buf.debounce_time {
			queue.push(msg_queue, msg)
			delete_key(&buf.messages, msg)
		}
	}
}

