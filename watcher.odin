package fswatch

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:path/filepath"
import "core:sync"
import chan "core:sync/chan"
import "core:thread"
import "core:time"

Watcher :: struct {
	arena:   ^virtual.Arena,
	chan:    _Msg_Chan,
	workers: [dynamic]_Worker,
}

_Worker :: struct {
	thread:      ^thread.Thread,
	data:        _Worker_Data,
	status_chan: chan.Chan(bool),
}

_Worker_Data :: struct {
	status_chan:   chan.Chan(bool),
	chan:          _Msg_Chan,
	debounce_time: time.Duration,
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
		workers = make([dynamic]_Worker),
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
	abs_path, ok := filepath.abs(path)
	if !ok {
		log.error("failed to create absolute path")
		return
	}
	status_chan, err := chan.create(chan.Chan(bool), 1, context.allocator)
	if err != nil {
		// TODO
		log.error(err)
		return
	}
	worker := _Worker {
		data = {
			path = abs_path,
			chan = watcher.chan,
			debounce_time = debounce_time,
			status_chan = status_chan,
			recursive = recursive,
		},
		status_chan = status_chan,
	}
	append(&watcher.workers, worker)
	w := &watcher.workers[len(watcher.workers) - 1]
	t := thread.create(_watch_worker)
	t.init_context = context
	t.user_index = 0
	t.data = &w.data
	thread.start(t)
	w.thread = t

	log.info("worker starting")
	recv_val: bool
	recv_val, ok = chan.recv(w.status_chan)
	if !ok || !recv_val {
		log.error("failed to start worker")
		return
	}
	log.debug("worker ready")
	return
}

destroy :: proc(watcher: ^Watcher) {
	chan.close(watcher.chan)
	for w in watcher.workers {
		thread.join(w.thread)
		free(w.thread)
	}
	virtual.arena_destroy(watcher.arena)
}

get_next_msg :: proc(watcher: ^Watcher) -> (msg: Msg, ok: bool) {
	return chan.try_recv(watcher.chan)
}

