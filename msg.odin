package fswatch

import "core:container/queue"
import "core:log"
import "core:sync/chan"
import "core:time"

_Msg_Chan :: chan.Chan(Msg)


Target :: enum {
	File,
	Dir,
}
Msg :: struct {
	target: Target,
	event:  Event,
}
Event :: union {
	Ev_Created,
	Ev_Modified,
	Ev_Moved,
	Ev_Removed,
	Ev_Renamed,
}

Ev_Created :: struct {
	path: string,
}
Ev_Modified :: struct {
	path: string,
}
Ev_Moved :: struct {
	from: string,
	to:   string,
}
Ev_Removed :: struct {
	path: string,
}
Ev_Renamed :: struct {
	old_path: string,
	new_path: string,
}

Msg_Buffer :: struct {
	throttle_time:  time.Duration,
	last_sent_time: time.Time,
	messages:       [dynamic]Msg,
}

_push_message :: proc(buf: ^Msg_Buffer, target: Target, ev: Event) {
	append(&buf.messages, Msg{target = target, event = ev})
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

