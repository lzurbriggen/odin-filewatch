#+build linux
package fswatch

import "core:c"
import "core:container/queue"
import "core:log"
import "core:mem/virtual"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

@(private)
Worker_State :: struct {
	msg_buf:    Msg_Buffer,
	root_path:  string,
	watches:    map[linux.Wd]string,
	inotify_fd: linux.Fd,
	ev_queue:   queue.Queue(^linux.Inotify_Event),
}

@(private)
watch_add :: proc(state: ^Worker_State, path: string) {
	wd, err := linux.inotify_add_watch(
		state.inotify_fd,
		strings.clone_to_cstring(path),
		{.CREATE, .CLOSE_WRITE, .DELETE, .MOVED_FROM, .MOVED_TO, .DONT_FOLLOW},
	)
	if err != nil {
		log.error(err)
		return
	}
	map_insert(&state.watches, wd, strings.clone(path))
}

@(private)
watch_remove :: proc(state: ^Worker_State, wd: linux.Wd) {
	delete_key(&state.watches, wd)
}

@(private)
walk_dir :: proc(state: ^Worker_State, path_rel: string) {
	watch_add(state, path_rel)
	walker := os2.walker_create(path_rel)
	defer os2.walker_destroy(&walker)
	for fi in os2.walker_walk(&walker) {
		watch_add(state, fi.fullpath)
	}
}

@(private)
worker_setup :: proc(data: ^Worker_Data) -> (state: Worker_State, ok: bool) {
	log.debug("Inotify init...")
	inotify_fd, err := linux.inotify_init1({.NONBLOCK})
	if err != .NONE {
		log.error(err)
		return {}, false
	}

	// ev_queue := queue.Queue(Msg){}
	// queue.init(&ev_queue)
	state = Worker_State {
		root_path  = strings.clone(data.path),
		inotify_fd = inotify_fd,
		watches    = make(map[linux.Wd]string),
		// ev_queue   = queue.make(),
	}

	walk_dir(&state, data.path)
	return state, true
}

@(private)
worker_handle_events :: proc(state: ^Worker_State) {
	watch_set := Fd_Set{}
	FD_ZERO(&watch_set)
	FD_SET(state.inotify_fd, &watch_set)

	linux.syscall(
		linux.SYS_select,
		uintptr(state.inotify_fd) + 1,
		&watch_set,
		uintptr(rawptr(nil)),
		uintptr(rawptr(nil)),
		&linux.Time_Val{seconds = 0, microseconds = 10000},
	)

	NAME_MAX :: 128
	MAX_BUF_SIZE :: size_of(linux.Inotify_Event) + NAME_MAX * 10 + 1
	read_buf := make([]u8, MAX_BUF_SIZE, allocator = context.temp_allocator)
	evs_len, err := linux.read(state.inotify_fd, read_buf)
	if err != nil && err != .EAGAIN {
		log.error(err)
		return
	}
	move_evs := make(map[u32]struct {
			target: Target,
			ev:     Ev_Moved,
		}, context.temp_allocator)
	i := 0
	for i < evs_len {
		event := cast(^linux.Inotify_Event)&read_buf[i]
		defer i += size_of(linux.Inotify_Event) + int(event.len)

		name_ptr := cast([^]u8)(&event.name)
		name := cast(cstring)name_ptr
		path, ok := state.watches[event.wd]
		if !ok {
			log.warn("Wd not in watches:", event.wd, name)
			continue
		}
		name_str := strings.clone_from_cstring_bounded(
			name,
			int(event.len),
			allocator = context.temp_allocator,
		)
		path_full := filepath.join({path, name_str}, context.temp_allocator)
		rel_path, rerr := filepath.rel(state.root_path, path_full, context.temp_allocator)
		if rerr != nil {
			log.error("Not able to build relative path", state.root_path, path_full, rerr)
			continue
		}

		target: Target = .Dir if .ISDIR in event.mask else .File

		// TODO: clean up
		if .IGNORED in event.mask {
			// watch_remove(&state, event.wd)
		} else if .CREATE in event.mask {
			_push_message(&state.msg_buf, target, Ev_Created{path = strings.clone(rel_path)})
			// TODO: walk new dir and push created messages for files
			if .ISDIR in event.mask {
				walker := os2.walker_create(path)
				defer os2.walker_destroy(&walker)
				log.debug("Walking new dir", path)
				for fi in os2.walker_walk(&walker) {
					log.debug("File in created dir found", fi.fullpath)
					// TODO: rel path
					file_rel_path, rerr := filepath.rel(state.root_path, fi.fullpath)
					if rerr != nil {
						log.error("Not able to build relative path", fi.fullpath, rerr)
						continue
					}
					target: Target = .Dir if fi.type == .Directory else .File
					_push_message(&state.msg_buf, target, Ev_Created{path = file_rel_path})
					if fi.type == .Directory {
						watch_add(state, strings.clone(fi.fullpath))
					}
				}
				watch_add(state, path)
			}
		} else if .DELETE in event.mask {
			_push_message(&state.msg_buf, target, Ev_Removed{path = strings.clone(rel_path)})
			if .ISDIR in event.mask {
				watch_remove(state, event.wd)
			}
		} else if .MOVED_FROM in event.mask {
			_, v, _, _ := map_entry(&move_evs, event.cookie)
			v.ev.from = strings.clone(rel_path)
		} else if .MOVED_TO in event.mask {
			_, v, _, _ := map_entry(&move_evs, event.cookie)
			v.ev.to = strings.clone(rel_path)
		} else if .CLOSE_WRITE in event.mask {
			_push_message(&state.msg_buf, target, Ev_Modified{path = strings.clone(rel_path)})
		} else {
			log.warn("unhandled", event)
		}
	}
	for _, msg in move_evs {
		_push_message(&state.msg_buf, msg.target, msg.ev)
	}
}

FD_SETSIZE :: 256

FD_SETIDXMASK :: (8 * size_of(u64))
FD_SETBITMASK :: (8 * size_of(u64) - 1)
Fd_Set :: struct {
	fds: [(FD_SETSIZE + FD_SETBITMASK) / FD_SETIDXMASK]u64,
}

FD_SET :: proc(fd: linux.Fd, set: ^Fd_Set) {
	__set := (set)
	__fd := uintptr(fd)
	if (__fd >= 0) {
		__set.fds[__fd / FD_SETIDXMASK] |= 1 << (__fd & FD_SETBITMASK)
	}
}

// #define FD_ISSET(fd, set) ({						
// 			fd_set *__set = (set);				
// 			int __fd = (fd);				
// 		int __r = 0;						
// 		if (__fd >= 0)						
// 			__r = !!(__set->fds[__fd / FD_SETIDXMASK] &	
// 1U << (__fd & FD_SETBITMASK));						
// 		__r;							
// 	})

FD_ZERO :: proc(set: ^Fd_Set) {
	__set := (set)
	__idx: c.int
	__size: c.int = (FD_SETSIZE + FD_SETBITMASK) / FD_SETIDXMASK
	for __idx := 0; i32(__idx) < __size; __idx += 1 {
		__set.fds[__idx] = 0
	}
}

