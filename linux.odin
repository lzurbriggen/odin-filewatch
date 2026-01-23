#+build linux
package fswatch

import "core:c"
import "core:container/queue"
import "core:hash"
import "core:log"
import "core:mem"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:sync/chan"
import "core:sys/linux"
import "core:thread"

Worker_State :: struct {
	root_path:  string,
	watches:    map[linux.Wd]string,
	inotify_fd: linux.Fd,
	ev_queue:   queue.Queue(^linux.Inotify_Event),
}

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
	map_insert(&state.watches, wd, path)
}

watch_remove :: proc(state: ^Worker_State, wd: linux.Wd) {
	delete_key(&state.watches, wd)
}

walk_dir :: proc(state: ^Worker_State, path_rel: string) {
	watch_add(state, path_rel)
	walker := os2.walker_create(path_rel)
	defer os2.walker_destroy(&walker)
	for fi in os2.walker_walk(&walker) {
		watch_add(state, fi.fullpath)
	}
}

file_handle_hash :: proc(fh: ^File_Handle) -> u64 {
	handle_bytes := cast(^u8)(cast(uintptr)fh + size_of(File_Handle))
	byte_slc := mem.slice_ptr(handle_bytes, int(fh.bytes))
	return hash.fnv64a(byte_slc)
}

_watch_worker :: proc(t: ^thread.Thread) {
	thread_data := cast(^_Worker_Data)t.data
	channel := thread_data.chan

	msg_queue := queue.Queue(Msg){}
	queue.init(&msg_queue)
	defer queue.destroy(&msg_queue)

	log.debug("Inotify init...")
	inotify_fd, err := linux.inotify_init1({.NONBLOCK})
	if err != .NONE {
		log.error(err)
		chan.send(thread_data.status_chan, false)
		return
	}

	state := Worker_State {
		root_path  = thread_data.path,
		inotify_fd = inotify_fd,
	}

	walk_dir(&state, thread_data.path)

	msg_buf := Msg_Buffer {
		throttle_time = thread_data.throttle_time,
	}
	// TODO: destroy proc
	defer delete(msg_buf.messages)

	log.info("Sending ready signal.")
	chan.send(thread_data.status_chan, true)

	fan_buf := make([]u8, 8192)
	for {
		if chan.is_closed(channel) {
			break
		}

		_tick(&msg_buf, &msg_queue)
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

		/* for select() */
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

		watch_set := Fd_Set{}
		FD_ZERO(&watch_set)
		FD_SET(state.inotify_fd, &watch_set)

		// TODO
		when ODIN_OS == .Linux {
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
			read_buf := make([]u8, MAX_BUF_SIZE)
			defer delete(read_buf)
			evs_len, err := linux.read(state.inotify_fd, read_buf)
			if err != nil && err != .EAGAIN {
				log.error(err)
				continue
			}
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
				path = filepath.join(
					{path, strings.clone_from_cstring_bounded(name, int(event.len))},
				)
				rel_path, rerr := filepath.rel(state.root_path, path)
				if rerr != nil {
					log.error("Not able to build relative path", rel_path, rerr)
					continue
				}
				// log.info(name, path, rel_path, event.mask)
				// TODO: clean up
				if .IGNORED in event.mask {
					// watch_remove(&state, event.wd)
				} else if .CREATE in event.mask {
					_push_message(&msg_buf, File_Created{path = rel_path})
					// TODO: walk new dir and push created messages for files
					if .ISDIR in event.mask {
						watch_add(&state, path)
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
							_push_message(&msg_buf, File_Created{path = file_rel_path})
							if fi.type == .Directory {
								watch_add(&state, fi.fullpath)
							}
						}
					}
				} else if .DELETE in event.mask || .DELETE_SELF in event.mask {
					_push_message(&msg_buf, File_Removed{path = rel_path})
					if .ISDIR in event.mask {
						watch_remove(&state, event.wd)
					}
				} else if .CLOSE_WRITE in event.mask {
					_push_message(&msg_buf, File_Modified{path = rel_path})
				} else {
					log.warn("unhandled", event)
				}
			}
		}
	}
	log.debug("stopping watcher thread")
}

file_handle_bytes :: proc(fh: ^File_Handle) -> ^u8 {
	return cast(^u8)(uintptr(fh) + size_of(File_Handle))
}

O_APPEND :: 000000010
/* not fcntl */
O_CREAT :: 000000400
/* not fcntl */
O_EXCL :: 000002000
O_LARGEFILE :: 000004000
__O_SYNC :: 000100000
O_SYNC :: (__O_SYNC | O_DSYNC)
O_NONBLOCK :: 000200000
/* not fcntl */
O_NOCTTY :: 000400000
O_DSYNC :: 001000000
O_NOATIME :: 004000000
/* set close_on_exec */
O_CLOEXEC :: 010000000

/* must be a directory */
O_DIRECTORY :: 000010000
/* don't follow links */
O_NOFOLLOW :: 000000200

O_PATH :: 020000000

File_Handle :: struct #packed {
	bytes: u32,
	type:  i32,
	// then handle_bytes follow
}

// TODO: not needed if moved to core lib
@(private)
errno_unwrap3 :: #force_inline proc "contextless" (
	ret: $P,
	$T: typeid,
	$U: typeid,
) -> (
	T,
	linux.Errno,
) where intrinsics.type_is_ordered_numeric(P) {
	if ret < 0 {
		default_value: T
		return default_value, Errno(-ret)
	} else {
		return T(transmute(U)ret), Errno(.NONE)
	}
}

@(private)
errno_unwrap2 :: #force_inline proc "contextless" (ret: $P, $T: typeid) -> (T, linux.Errno) {
	if ret < 0 {
		default_value: T
		return default_value, linux.Errno(-ret)
	} else {
		return T(ret), linux.Errno(.NONE)
	}
}

@(private)
errno_unwrap :: proc {
	errno_unwrap2,
	errno_unwrap3,
}

