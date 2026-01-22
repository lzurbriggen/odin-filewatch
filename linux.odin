#+build linux
package fswatch

import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:sys/linux"
import "core:thread"

_watch_worker :: proc(t: ^thread.Thread) {
	thread_data := cast(^_Worker_Data)t.data
	channel := thread_data.chan

	msg_queue := queue.Queue(Msg){}
	queue.init(&msg_queue)
	defer queue.destroy(&msg_queue)
	// log.debug(thread_data.path)

	log.debug("Fanotify init...")
	// TODO: O_LARGEFILE?
	fd, err := fanotify_init(
		FAN_CLASS_NOTIF | FAN_REPORT_FID | FAN_REPORT_DIR_FID | FAN_REPORT_DFID_NAME,
		os.O_RDONLY,
	)
	if err != .NONE {
		log.error(err)
		chan.send(thread_data.status_chan, false)
		return
	}

	log.debug("Fanotify mark...")
	mark: int

	mask := FAN_MODIFY | FAN_DELETE | FAN_CREATE | FAN_ONDIR | FAN_ATTRIB
	if thread_data.recursive {
		mask |= FAN_EVENT_ON_CHILD
	}
	mark, err = fanotify_mark(
		fd,
		FAN_MARK_ADD,
		mask,
		linux.AT_FDCWD,
		strings.clone_to_cstring(thread_data.path),
	)
	if err != .NONE {
		log.error(err)
		chan.send(thread_data.status_chan, false)
		return
	}

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

		// TODO
		when ODIN_OS == .Linux {
			res, err := linux.read(fd, fan_buf)
			if err != .NONE {
				log.error("Error when reading fanotify buffer:", err)
				// TODO
			}
			event := cast(^fanotify_event_metadata)&fan_buf[0]

			off: int
			curr_len := res
			for FAN_EVENT_OK(event, curr_len) {
				defer event = FAN_EVENT_NEXT(event, &curr_len)
				// TODO: log
				// if event.mask != FAN_FS_ERROR {
				// 	continue
				// }
				// if event.fd != FAN_NOFD {
				// 	continue
				// }

				// TODO: size of ptr instead?
				off = size_of(fanotify_event_metadata)
				for off < int(event.event_len) {
					info := cast(^fanotify_event_info_header)(uintptr(event) + uintptr(off))

					log.info(info)

					#partial switch info.info_type {
					case .FAN_EVENT_INFO_TYPE_DFID_NAME:
						fid := cast(^fanotify_event_info_fid)info
						fh := cast(^File_Handle)(uintptr(fid) + size_of(fanotify_event_info_fid))
						str_ptr := cast(^u8)(uintptr(fh) +
							size_of(File_Handle) +
							uintptr(fh.bytes))
						name := transmute(cstring)str_ptr
						log.info("name", name)
					case .FAN_EVENT_INFO_TYPE_DFID:
					// fid := cast(^fanotify_event_info_fid)info

					// // pointer to struct file_handle inside the event
					// fh := cast(^os.Handle)(uintptr(fid) + size_of(fanotify_event_info_fid))

					// mount_fd, err := linux.open(
					// 	strings.clone_to_cstring(thread_data.path),
					// 	{.PATH, .DIRECTORY},
					// 	nil,
					// )
					// fd := linux.syscall(
					// 	linux.SYS_open_by_handle_at,
					// 	mount_fd,
					// 	fh,
					// 	os.O_RDONLY | os.O_CLOEXEC,
					// )

					// if fd < 0 {
					// 	// err := os.errno()
					// 	log.error("open_by_handle_at failed", err)
					// } else {
					// 	// fd is now an open fd to the object
					// }
					// // fid.handle
					// // linux.SYS_open_by_handle_at
					// // TODO
					// buf := make([]u8, 8192)
					// pathlen: int
					// pathlen, err = linux.readlink(fmt.ctprintf("/proc/self/fd/%i", fd), buf)
					// // log.info(
					// // 	transmute(cstring)&buf[0], // fmt.ctprintf("/proc/self/fd/%i", event.fd),
					// // )
					// log.info(transmute(cstring)(&buf))
					case .FAN_EVENT_INFO_TYPE_FID:
					// fid := cast(^fanotify_event_info_fid)info
					// open_res := linux.syscall(
					// 	linux.SYS_open_by_handle_at,
					// 	fid.fsid,
					// 	&fid.handle[0],
					// )
					// // fid.handle
					// // linux.SYS_open_by_handle_at
					// // TODO
					// buf := make([]u8, 8192)
					// pathlen, err := linux.readlink(
					// 	fmt.ctprintf("/proc/self/fd/%i", event.fd),
					// 	buf,
					// )
					// // log.info(
					// // 	transmute(cstring)&buf[0], // fmt.ctprintf("/proc/self/fd/%i", event.fd),
					// // )
					// log.info(transmute(cstring)(&buf))
					// if pathlen != -1 {

					// }
					}
					if info.len < size_of(fanotify_event_info_header) {
						log.warn("corrupted info?")
						break
					}
					off += int(info.len)

				}
			}
		} else {
			panic("only Windows is supported at the moment")
		}
	}
	log.debug("stopping watcher thread")
}

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

FAN_EVENT_METADATA_LEN :: size_of(fanotify_event_metadata)

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
	ret := linux.syscall(linux.SYS_fanotify_init, flags, event_f_flags)
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
		linux.SYS_fanotify_mark,
		c.int(fanotify_fd),
		c.uint(flags),
		c.uint64_t(mask),
		c.int(dirfd),
		uintptr(rawptr(pathname)),
	)
	return errno_unwrap(ret, int)
}


fanotify_event_metadata :: struct #packed {
	event_len:    u32,
	vers:         u8,
	reserved:     u8,
	metadata_len: u16,
	// TODO: 8-byte alignment relevant? original type is: aligned_u64
	mask:         u64,
	fd:           linux.Fd,
	pid:          linux.Pid,
}

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

fanotify_event_info_header :: struct #packed {
	info_type: Fanotify_Event_Info_Type,
	pad:       u8,
	len:       u16,
}

kernel_fsid_t :: struct {
	val: [2]int,
}

fanotify_event_info_fid :: struct #packed {
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

