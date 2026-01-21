#+build linux
package fswatch

import "core:c"
import "core:container/queue"
import "core:log"
import "core:os"
import "core:sync/chan"
import "core:sys/linux"
import "core:thread"

_watch_worker :: proc(t: ^thread.Thread) {
	thread_data := cast(^_Worker_Data)t.data
	channel := thread_data.chan

	msg_queue := queue.Queue(Msg){}
	queue.init(&msg_queue)
	defer queue.destroy(&msg_queue)
	log.debug(thread_data.path)

	fd, err := fanotify_init({.FAN_CLASS_NOTIF}, os.O_RDONLY)
	if err != .NONE {
		return
	}

	mark: int
	mark, err = fanotify_mark(
		fd,
		FAN_MARK_ADD | FAN_MARK_FILESYSTEM,
		.FAN_FS_ERROR,
		linux.AT_FDCWD,
		"path",
	)
	if err != .NONE {
		return
	}


	msg_buf := Msg_Buffer {
		debounce_time = thread_data.debounce_time,
	}
	// TODO: destroy proc
	defer delete(msg_buf.messages)

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
				// TODO
			}
			event := transmute(^fanotify_event_metadata)&fan_buf
			info: ^fanotify_event_info_header
			fan_err: ^fanotify_event_info_error
			fid: ^fanotify_event_info_fid
			off: int

			curr_len := len(fan_buf)
			for {
				if !FAN_EVENT_OK(event, curr_len) {
					break
				}
				event = FAN_EVENT_NEXT(event, &curr_len)

				// TODO: log
				// if event.mask != FAN_FS_ERROR {
				// 	continue
				// }
				// if event.fd != FAN_NOFD {
				// 	continue
				// }

				off = size_of(&event)
				for {
					if off >= int(event.event_len) {
						break
					}
					off += int(info.len)
					info = cast(^fanotify_event_info_header)(uintptr(event) + uintptr(off))

					#partial switch info.info_type {
					case .FAN_EVENT_INFO_TYPE_ERROR:
					case .FAN_EVENT_INFO_TYPE_FID:
						fid := cast(^fanotify_event_info_fid)info
						// fid.handle
						// linux.SYS_open_by_handle_at
						// TODO
						buf := make([]u8, 8192)
					// rc, err := linux.readlink("/proc/self/fd/" + event.fd, buf)
					}
				}
			}
		} else {
			panic("only Windows is supported at the moment")
		}
	}
	log.debug("stopping watcher thread")
}


FAN_EVENT_NEXT :: proc(meta: ^fanotify_event_metadata, len: ^int) -> ^fanotify_event_metadata {
	len^ -= int(meta.event_len)
	new_ptr := uintptr(meta) + uintptr(meta.event_len)
	return transmute(^fanotify_event_metadata)new_ptr
}

FAN_EVENT_METADATA_LEN :: size_of(fanotify_event_metadata)

FAN_EVENT_OK :: proc(meta: ^fanotify_event_metadata, len: int) -> bool {
	return(
		i64(len) >= i64(FAN_EVENT_METADATA_LEN) &&
		i64(meta.event_len) >= i64(FAN_EVENT_METADATA_LEN) &&
		i64(meta.event_len) <= i64(len) \
	)
}

Fanotify_Flag :: enum c.uint64_t {
	FAN_CLOEXEC           = 0x00000001,
	FAN_NONBLOCK          = 0x00000002,
	FAN_CLASS_NOTIF       = 0x00000000,
	FAN_CLASS_CONTENT     = 0x00000004,
	FAN_CLASS_PRE_CONTENT = 0x00000008,
	FAN_UNLIMITED_QUEUE   = 0x00000010,
	FAN_UNLIMITED_MARKS   = 0x00000020,
	FAN_ENABLE_AUDIT      = 0x00000040,
}
Fanotify_Flags :: bit_set[Fanotify_Flag]

Fanotify_Event_Format :: enum c.uint64_t {
	/* Report pidfd for event->pid */
	FAN_REPORT_PIDFD      = 0x00000080,
	/* event->pid is thread id */
	FAN_REPORT_TID        = 0x00000100,
	/* Report unique file id */
	FAN_REPORT_FID        = 0x00000200,
	/* Report unique directory id */
	FAN_REPORT_DIR_FID    = 0x00000400,
	/* Report events with name */
	FAN_REPORT_NAME       = 0x00000800,
	/* Report dirent target id  */
	FAN_REPORT_TARGET_FID = 0x00001000,
	/* event->fd can report error */
	FAN_REPORT_FD_ERROR   = 0x00002000,
	/* Report mount events */
	FAN_REPORT_MNT        = 0x00004000,
}

fanotify_init :: proc "contextless" (
	flags: Fanotify_Flags,
	event_f_flags: uint,
) -> (
	linux.Fd,
	linux.Errno,
) {
	ret := linux.syscall(linux.SYS_fanotify_init, flags, event_f_flags)
	return errno_unwrap(ret, linux.Fd)
}

Fan_Event :: enum c.uint64_t {
	/* File was accessed */
	FAN_ACCESS         = 0x00000001,
	/* File was modified */
	FAN_MODIFY         = 0x00000002,
	/* Metadata changed */
	FAN_ATTRIB         = 0x00000004,
	/* Writable file closed */
	FAN_CLOSE_WRITE    = 0x00000008,
	/* Unwritable file closed */
	FAN_CLOSE_NOWRITE  = 0x00000010,
	/* File was opened */
	FAN_OPEN           = 0x00000020,
	/* File was moved from X */
	FAN_MOVED_FROM     = 0x00000040,
	/* File was moved to Y */
	FAN_MOVED_TO       = 0x00000080,
	/* Subfile was created */
	FAN_CREATE         = 0x00000100,
	/* Subfile was deleted */
	FAN_DELETE         = 0x00000200,
	/* Self was deleted */
	FAN_DELETE_SELF    = 0x00000400,
	/* Self was moved */
	FAN_MOVE_SELF      = 0x00000800,
	/* File was opened for exec */
	FAN_OPEN_EXEC      = 0x00001000,

	/* Event queued overflowed */
	FAN_Q_OVERFLOW     = 0x00004000,
	/* Filesystem error */
	FAN_FS_ERROR       = 0x00008000,

	/* File open in perm check */
	FAN_OPEN_PERM      = 0x00010000,
	/* File accessed in perm check */
	FAN_ACCESS_PERM    = 0x00020000,
	/* File open/exec in perm check */
	FAN_OPEN_EXEC_PERM = 0x00040000,

	/* Pre-content access hook */
	FAN_PRE_ACCESS     = 0x00100000,
	/* Mount was attached */
	FAN_MNT_ATTACH     = 0x01000000,
	/* Mount was detached */
	FAN_MNT_DETACH     = 0x02000000,

	/* Interested in child events */
	FAN_EVENT_ON_CHILD = 0x08000000,

	/* File was renamed */
	FAN_RENAME         = 0x10000000,

	/* Event occurred against dir */
	FAN_ONDIR          = 0x40000000,
}

Fanotify_Mark_Flags :: distinct u64

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
	ret := linux.syscall(linux.SYS_fanotify_mark, fanotify_fd, flags, mask, dirfd, pathname)
	return errno_unwrap(ret, int)
}


fanotify_event_metadata :: struct {
	event_len:    u32,
	vers:         u8,
	reserved:     u8,
	metadata_len: u16,
	// TODO: 8-byte alignment relevant? original type is: aligned_u64
	mask:         u64,
	fd:           linux.Fd,
	pid:          linux.Pid,
}

Fanotify_Event_Info_Type :: enum {
	FAN_EVENT_INFO_TYPE_FID       = 1,
	FAN_EVENT_INFO_TYPE_DFID_NAME = 2,
	FAN_EVENT_INFO_TYPE_DFID      = 3,
	FAN_EVENT_INFO_TYPE_PIDFD     = 4,
	FAN_EVENT_INFO_TYPE_ERROR     = 5,
	FAN_EVENT_INFO_TYPE_RANGE     = 6,
	FAN_EVENT_INFO_TYPE_MNT       = 7,
}

fanotify_event_info_header :: struct {
	info_type: Fanotify_Event_Info_Type,
	pad:       u8,
	len:       u16,
}

kernel_fsid_t :: struct {
	val: [2]int,
}

fanotify_event_info_fid :: struct {
	hdr:    fanotify_event_info_header,
	fsid:   kernel_fsid_t,
	/*
	 * Following is an opaque struct file_handle that can be passed as
	 * an argument to open_by_handle_at(2).
	 */
	// TODO: unsigned char[] ?
	handle: []c.char,
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

