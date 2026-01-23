#+build linux
package fswatch

import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem"
import "core:os"
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

Dir_Id :: struct {
	fsid:        kernel_fsid_t,
	handle_hash: u64,
}

watch_add :: proc(state: ^Worker_State, path: string) {
	log.debug("Watch:", path)
	wd, err := linux.inotify_add_watch(
		state.inotify_fd,
		strings.clone_to_cstring(path),
		{
			.MODIFY,
			.CREATE,
			.DELETE,
			.MOVED_FROM,
			.MOVED_TO,
			.DONT_FOLLOW,
			.DELETE_SELF,
			.MOVE_SELF,
		},
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

// TODO: flags type
name_to_handle_at :: proc(
	dirfd: linux.Fd,
	path: cstring,
	handle: ^File_Handle,
	mount_id: ^kernel_fsid_t,
	flags: c.int,
) -> (
	int,
	linux.Errno,
) {
	ret := linux.syscall(
		linux.SYS_select,
		dirfd,
		uintptr(rawptr(path)),
		uintptr(handle),
		uintptr(mount_id),
		uintptr(flags),
	)
	return errno_unwrap(ret, int)
}

_watch_worker :: proc(t: ^thread.Thread) {
	thread_data := cast(^_Worker_Data)t.data
	channel := thread_data.chan

	msg_queue := queue.Queue(Msg){}
	queue.init(&msg_queue)
	defer queue.destroy(&msg_queue)
	// log.debug(thread_data.path)

	log.debug("Inotify init...")
	inotify_fd, err := linux.inotify_init1({.NONBLOCK})
	if err != .NONE {
		log.error(err)
		chan.send(thread_data.status_chan, false)
		return
	}

	state := Worker_State {
		root_path  = thread_data.path,
		// dir_paths  = make(map[Dir_Id]string),
		inotify_fd = inotify_fd,
	}

	walk_dir(&state, thread_data.path)

	msg_buf := Msg_Buffer {
		debounce_time = thread_data.debounce_time,
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
			msg := queue.back_ptr(&msg_queue)
			if msg == nil {
				break
			}
			if msg == nil {
				break
			}
			ok := chan.try_send(channel, msg^)
			if !ok {
				break
			}
			queue.pop_back(&msg_queue)
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
				log.info(evs_len, i)
				event := cast(^linux.Inotify_Event)&read_buf[i]
				defer i += size_of(linux.Inotify_Event) + int(event.len)

				// len, err := linux.read(state.inotify_fd, read_buf)
				// if err != nil && err != .EAGAIN {
				// 	log.error(err)
				// 	continue
				// }
				// if len <= 0 {
				// 	continue
				// }

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
				log.info(name, path, rel_path, event.mask)
				// TODO: clean up
				if .CREATE in event.mask {
					_push_message(&msg_buf, File_Created{path = rel_path})
					watch_add(&state, path)
					// TODO: walk new dir and push created messages for files
					if .ISDIR in event.mask {
						walker := os2.walker_create(path)
						defer os2.walker_destroy(&walker)
						log.debug("Walking new dir", path)
						for fi in os2.walker_walk(&walker) {
							log.debug("File in created dir found", fi.fullpath)
							// TODO: rel path
							rel_path, rerr := filepath.rel(state.root_path, fi.fullpath)
							if rerr != nil {
								log.error("Not able to build relative path", fi.fullpath, rerr)
								continue
							}
							_push_message(&msg_buf, File_Created{path = rel_path})
						}
					}
				} else if .DELETE in event.mask || .DELETE_SELF in event.mask {
					_push_message(&msg_buf, File_Removed{path = rel_path})
					// watch_remove(&state, event.wd)
				} else if .MODIFY in event.mask {
					_push_message(&msg_buf, File_Modified{path = rel_path})
				} else {
					log.warn("unhandled", event)
				}
			}
		}
	}
	log.debug("stopping watcher thread")
}

extract_dfid_name :: proc(
	event: ^fanotify_event_metadata,
	info: ^fanotify_event_info_header,
) -> (
	parent_fh: ^File_Handle,
	child_name: string,
	ok: bool,
) {
	if info.info_type != .FAN_EVENT_INFO_TYPE_DFID_NAME {
		return
	}

	fid := cast(^fanotify_event_info_fid)info

	parent_fh = cast(^File_Handle)(uintptr(fid) + size_of(fanotify_event_info_fid))

	name_ptr := cast(^u8)(uintptr(parent_fh) + size_of(File_Handle) + uintptr(parent_fh.bytes))

	info_start := uintptr(info)
	info_end := info_start + uintptr(info.len)

	if uintptr(name_ptr) >= info_end {
		log.warn("DFID_NAME name_ptr past end of info")
		return
	}

	child_name = strings.clone_from_cstring(transmute(cstring)(name_ptr))
	ok = true
	return
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
	// TODO: type?
	type:  i32,
	// then handle_bytes follow
}

FAN_EVENT_NEXT :: proc(meta: ^fanotify_event_metadata, len: ^int) -> ^fanotify_event_metadata {
	len^ -= int(meta.event_len)
	new_ptr := uintptr(meta) + uintptr(meta.event_len)
	return transmute(^fanotify_event_metadata)new_ptr
}


FAN_EVENT_OK :: proc(meta: ^fanotify_event_metadata, len: int) -> bool {
	// log.debug(
	// 	i64(len),
	// 	i64(FAN_EVENT_METADATA_LEN),
	// 	i64(meta.event_len),
	// 	i64(len) >= i64(FAN_EVENT_METADATA_LEN),
	// 	i64(meta.event_len) >= i64(FAN_EVENT_METADATA_LEN),
	// 	i64(meta.event_len) <= i64(len),
	// )
	return(
		i64(len) >= i64(FAN_EVENT_METADATA_LEN) &&
		i64(meta.event_len) >= i64(FAN_EVENT_METADATA_LEN) &&
		i64(meta.event_len) <= i64(len) \
	)
}

Fanotify_Flag :: distinct c.int

FAN_CLOEXEC: Fanotify_Flag = 0x00000001
FAN_NONBLOCK: Fanotify_Flag = 0x00000002
FAN_CLASS_NOTIF: Fanotify_Flag = 0x00000000
FAN_CLASS_CONTENT: Fanotify_Flag = 0x00000004
FAN_CLASS_PRE_CONTENT: Fanotify_Flag = 0x00000008
FAN_UNLIMITED_QUEUE: Fanotify_Flag = 0x00000010
FAN_UNLIMITED_MARKS: Fanotify_Flag = 0x00000020
FAN_ENABLE_AUDIT: Fanotify_Flag = 0x00000040

/* Report pidfd for event->pid */
FAN_REPORT_PIDFD: Fanotify_Flag : 0x00000080
/* event->pid is thread id */
FAN_REPORT_TID: Fanotify_Flag : 0x00000100
/* Report unique file id */
FAN_REPORT_FID: Fanotify_Flag : 0x00000200
/* Report unique directory id */
FAN_REPORT_DIR_FID: Fanotify_Flag : 0x00000400
/* Report events with name */
FAN_REPORT_NAME: Fanotify_Flag : 0x00000800
/* Report dirent target id  */
FAN_REPORT_TARGET_FID: Fanotify_Flag : 0x00001000
/* event->fd can report error */
FAN_REPORT_FD_ERROR: Fanotify_Flag : 0x00002000
/* Report mount events */
FAN_REPORT_MNT: Fanotify_Flag = 0x00004000
FAN_REPORT_DFID_NAME :: FAN_REPORT_DIR_FID | FAN_REPORT_NAME
FAN_REPORT_DFID_NAME_TARGET :: FAN_REPORT_DFID_NAME | FAN_REPORT_FID | FAN_REPORT_TARGET_FID

fanotify_init :: proc "contextless" (
	flags: Fanotify_Flag,
	event_f_flags: uint,
) -> (
	linux.Fd,
	linux.Errno,
) {
	ret := linux.syscall(linux.SYS_select, flags, event_f_flags)
	return errno_unwrap(ret, linux.Fd)
}

Fan_Event :: distinct c.uint64_t
/* File was accessed */
FAN_ACCESS: Fan_Event = 0x00000001
/* File was modified */
FAN_MODIFY: Fan_Event = 0x00000002
/* Metadata changed */
FAN_ATTRIB: Fan_Event = 0x00000004
/* Writable file closed */
FAN_CLOSE_WRITE: Fan_Event = 0x00000008
/* Unwritable file closed */
FAN_CLOSE_NOWRITE: Fan_Event = 0x00000010
/* File was opened */
FAN_OPEN: Fan_Event = 0x00000020
/* File was moved from X */
FAN_MOVED_FROM: Fan_Event = 0x00000040
/* File was moved to Y */
FAN_MOVED_TO: Fan_Event = 0x00000080
/* Subfile was created */
FAN_CREATE: Fan_Event = 0x00000100
/* Subfile was deleted */
FAN_DELETE: Fan_Event = 0x00000200
/* Self was deleted */
FAN_DELETE_SELF: Fan_Event = 0x00000400
/* Self was moved */
FAN_MOVE_SELF: Fan_Event = 0x00000800
/* File was opened for exec */
FAN_OPEN_EXEC: Fan_Event = 0x00001000

/* Event queued overflowed */
FAN_Q_OVERFLOW: Fan_Event = 0x00004000
/* Filesystem error */
FAN_FS_ERROR: Fan_Event = 0x00008000

/* File open in perm check */
FAN_OPEN_PERM: Fan_Event = 0x00010000
/* File accessed in perm check */
FAN_ACCESS_PERM: Fan_Event = 0x00020000
/* File open/exec in perm check */
FAN_OPEN_EXEC_PERM: Fan_Event = 0x00040000

/* Pre-content access hook */
FAN_PRE_ACCESS: Fan_Event = 0x00100000
/* Mount was attached */
FAN_MNT_ATTACH: Fan_Event = 0x01000000
/* Mount was detached */
FAN_MNT_DETACH: Fan_Event = 0x02000000

/* Interested in child events */
FAN_EVENT_ON_CHILD: Fan_Event = 0x08000000

/* File was renamed */
FAN_RENAME: Fan_Event = 0x10000000

/* Event occurred against dir */
FAN_ONDIR: Fan_Event = 0x40000000


Fanotify_Mark_Flags :: distinct c.uint

FAN_MARK_ADD: Fanotify_Mark_Flags = 0x00000001
FAN_MARK_REMOVE: Fanotify_Mark_Flags = 0x00000002
FAN_MARK_DONT_FOLLOW: Fanotify_Mark_Flags = 0x00000004
FAN_MARK_ONLYDIR: Fanotify_Mark_Flags = 0x00000008
FAN_MARK_IGNORED_MASK: Fanotify_Mark_Flags = 0x00000020
FAN_MARK_IGNORED_SURV_MODIFY: Fanotify_Mark_Flags = 0x00000040
FAN_MARK_FLUSH: Fanotify_Mark_Flags = 0x00000080
FAN_MARK_EVICTABLE: Fanotify_Mark_Flags = 0x00000200
FAN_MARK_IGNORE: Fanotify_Mark_Flags = 0x00000400
FAN_MARK_INODE: Fanotify_Mark_Flags = 0x00000000
FAN_MARK_MOUNT: Fanotify_Mark_Flags = 0x00000010
FAN_MARK_FILESYSTEM: Fanotify_Mark_Flags = 0x00000100
FAN_MARK_MNTNS: Fanotify_Mark_Flags = 0x00000110

fanotify_mark :: proc "contextless" (
	fanotify_fd: linux.Fd,
	flags: Fanotify_Mark_Flags,
	mask: Fan_Event,
	dirfd: linux.Fd,
	pathname: cstring,
) -> (
	int,
	linux.Errno,
) {
	ret := linux.syscall(
		linux.SYS_select,
		c.int(fanotify_fd),
		c.uint(flags),
		c.uint64_t(mask),
		c.int(dirfd),
		uintptr(rawptr(pathname)),
	)
	return errno_unwrap(ret, int)
}

fanotify_event_metadata :: struct {
	event_len:    u32,
	vers:         u8,
	reserved:     u8,
	metadata_len: u16,
	mask:         Fan_Event,
	fd:           linux.Fd,
	pid:          linux.Pid,
}
FAN_EVENT_METADATA_LEN :: size_of(fanotify_event_metadata)

Fanotify_Event_Info_Type :: enum u8 {
	FAN_EVENT_INFO_TYPE_FID           = 1,
	FAN_EVENT_INFO_TYPE_DFID_NAME     = 2,
	FAN_EVENT_INFO_TYPE_DFID          = 3,
	FAN_EVENT_INFO_TYPE_PIDFD         = 4,
	FAN_EVENT_INFO_TYPE_ERROR         = 5,
	FAN_EVENT_INFO_TYPE_RANGE         = 6,
	FAN_EVENT_INFO_TYPE_MNT           = 7,
	FAN_EVENT_INFO_TYPE_OLD_DFID_NAME = 10,
	FAN_EVENT_INFO_TYPE_NEW_DFID_NAME = 12,
}

fanotify_event_info_header :: struct {
	info_type: Fanotify_Event_Info_Type,
	pad:       u8,
	len:       u16,
}

kernel_fsid_t :: struct #packed {
	val: [2]c.int,
}

fanotify_event_info_fid :: struct {
	hdr:  fanotify_event_info_header,
	fsid: kernel_fsid_t,
	/*
	 * Following is an opaque struct file_handle that can be passed as
	 * an argument to open_by_handle_at(2).
	 */
}

/*
 * This structure is used for info records of type FAN_EVENT_INFO_TYPE_PIDFD.
 * It holds a pidfd for the pid that was responsible for generating an event.
 */
fanotify_event_info_pidfd :: struct {
	hdr:   fanotify_event_info_header,
	pidfd: linux.Pid_FD,
}

fanotify_event_info_error :: struct {
	hdr:         fanotify_event_info_header,
	// TODO: underlying type should be right. semantic meaning?
	error:       linux.Fd,
	error_count: u32,
}

fanotify_event_info_range :: struct {
	hdr:    fanotify_event_info_header,
	pad:    u32,
	offset: u64,
	count:  u64,
}

fanotify_event_info_mnt :: struct {
	hdr:    fanotify_event_info_header,
	mnt_id: u64,
}

fanotify_response :: struct {
	fd:       linux.Fd,
	response: u32,
}

fanotify_response_info_header :: struct {
	type: u8,
	pad:  u8,
	len:  u16,
}

fanotify_response_info_audit_rule :: struct {
	hdr:         fanotify_response_info_header,
	rule_number: u32,
	subj_trust:  u32,
	obj_trust:   u32,
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

