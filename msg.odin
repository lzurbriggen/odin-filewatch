package fswatch

import "core:container/queue"
import "core:log"
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
	throttle_time:  time.Duration,
	last_sent_time: time.Time,
	messages:       [dynamic]Msg,
}

_push_message :: proc(buf: ^Msg_Buffer, msg: Msg) {
	append(&buf.messages, msg)
}

_tick :: proc(buf: ^Msg_Buffer, msg_queue: ^queue.Queue(Msg)) {
	if time.diff(buf.last_sent_time, time.now()) >= buf.throttle_time {
		buf.last_sent_time = time.now()
		last_msg: Msg
		for msg, i in buf.messages {
			if msg == last_msg {
				// hack to fix duplicate events
				log.warn("Duplicate event:", msg)
				continue
			}
			last_msg = msg
			queue.push(msg_queue, msg)
		}
		clear(&buf.messages)
	}
}

