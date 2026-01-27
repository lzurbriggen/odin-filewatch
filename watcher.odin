package dirwatch

import "base:runtime"
import "core:container/queue"
import "core:log"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import chan "core:sync/chan"
import "core:thread"
import "core:time"

Watcher :: struct {
	arena:   ^virtual.Arena,
	chan:    _Msg_Chan,
	workers: [dynamic]Worker,
}

@(private)
Worker :: struct {
	thread: ^thread.Thread,
	data:   Worker_Data,
}

@(private)
Worker_Data :: struct {
	arena:         ^virtual.Arena,
	temp_arena:    ^virtual.Arena,
	status_chan:   chan.Chan(bool),
	chan:          _Msg_Chan,
	throttle_time: time.Duration,
	path:          string,
	recursive:     bool,
}

create :: proc(channel_size: int) -> (Watcher, runtime.Allocator_Error) {
	arena := new(virtual.Arena)
	err := virtual.arena_init_growing(arena)
	if err != nil {
		return {}, err
	}
	alloc := virtual.arena_allocator(arena)
	context.allocator = alloc

	watcher := Watcher {
		arena   = arena,
		workers = make([dynamic]Worker),
	}

	{
		channel, err := chan.create(_Msg_Chan, channel_size, context.allocator)
		if err != nil {
			return {}, err
		}
		watcher.chan = channel
	}

	return watcher, nil
}

watch_dir :: proc(
	watcher: ^Watcher,
	path: string,
	debounce_time: time.Duration = 0,
	recursive := false,
) {
	arena := new(virtual.Arena)
	err := virtual.arena_init_growing(arena)
	if err != nil {
		// TODO
		log.error(err)
		return
	}
	alloc := virtual.arena_allocator(arena)
	context.allocator = alloc

	temp_arena := new(virtual.Arena)
	err = virtual.arena_init_growing(temp_arena)
	if err != nil {
		// TODO
		log.error(err)
		return
	}


	abs_path, ok := filepath.abs(path)
	if !ok {
		log.error("failed to create absolute path")
		return
	}
	log.debug("Watching path:", abs_path)
	status_chan: chan.Chan(bool)
	status_chan, err = chan.create(chan.Chan(bool), 1, context.allocator)
	if err != nil {
		// TODO
		log.error(err)
		return
	}
	worker := Worker {
		data = {
			arena = arena,
			temp_arena = temp_arena,
			path = strings.clone(abs_path),
			chan = watcher.chan,
			throttle_time = debounce_time,
			status_chan = status_chan,
			recursive = recursive,
		},
	}
	append(&watcher.workers, worker)
	w := &watcher.workers[len(watcher.workers) - 1]
	t := thread.create(worker_run)
	t.init_context = context
	t.user_index = 0
	t.data = &w.data
	thread.start(t)
	w.thread = t

	log.debug("Worker starting...")
	recv_val: bool
	recv_val, ok = chan.recv(w.data.status_chan)
	if !ok || !recv_val {
		log.error("failed to start worker")
		return
	}
	log.debug("Worker ready.")
	return
}

destroy :: proc(watcher: ^Watcher) {
	chan.close(watcher.chan)
	for w in watcher.workers {
		chan.close(w.data.status_chan)
		thread.join(w.thread)
		virtual.arena_destroy(w.data.arena)
		free(w.data.arena)
	}
	virtual.arena_destroy(watcher.arena)
	free(watcher.arena)
}

get_next_msg :: proc(watcher: ^Watcher) -> (msg: Msg, ok: bool) {
	return chan.try_recv(watcher.chan)
}

@(private)
worker_run :: proc(t: ^thread.Thread) {
	thread_data := cast(^Worker_Data)t.data
	context.allocator = virtual.arena_allocator(thread_data.arena)
	context.temp_allocator = virtual.arena_allocator(thread_data.temp_arena)

	channel := thread_data.chan

	msg_queue := queue.Queue(Msg){}
	queue.init(&msg_queue)
	defer queue.destroy(&msg_queue)

	state, ok := worker_setup(thread_data)
	if !ok {
		chan.send(thread_data.status_chan, false)
	}

	state.msg_buf = Msg_Buffer {
		throttle_time = thread_data.throttle_time,
		messages      = make([dynamic]Msg),
	}

	log.debug("Sending ready signal.")
	chan.send(thread_data.status_chan, true)

	for {
		arena_temp := virtual.arena_temp_begin(thread_data.temp_arena)
		free_all(context.temp_allocator)

		if chan.is_closed(channel) {
			break
		}

		_tick(&state.msg_buf, &msg_queue)
		for queue.len(msg_queue) > 0 {
			msg := queue.front_ptr(&msg_queue)
			if msg == nil {
				break
			}
			ok := chan.try_send(channel, msg^)
			if !ok {
				break
			}
			queue.pop_front(&msg_queue)
		}

		worker_handle_events(&state)
	}

	log.debug("Stopping watcher thread.")
}

