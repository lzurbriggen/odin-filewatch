#+build windows
package fswatch

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync/chan"
import "core:sys/windows"
import "core:thread"

Windows_Entry :: struct #align (4) {
	handle:    windows.HANDLE,
	ov:        windows.OVERLAPPED,
	recursive: windows.BOOL,
	path:      string,
	mask:      windows.UINT64,
	buf:       []byte,
}

windows_entry :: proc(path: string) -> Windows_Entry {
	handle := windows.CreateFileW(
		windows.utf8_to_wstring(path),
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if (handle == windows.INVALID_HANDLE_VALUE) {
		log.error("invalid handle")
		// TODO
		return Windows_Entry{}
	}

	fi: windows.BY_HANDLE_FILE_INFORMATION
	if !windows.GetFileInformationByHandle(handle, &fi) {
		windows.CloseHandle(handle)
		err := os.get_last_error()
		if platform_err, ok := err.(os.Platform_Error); ok {

		}
		log.error("failed to get file information handle", err)
		// TODO:
		return Windows_Entry{}
	}
	// fi.dwVolumeSerialNumber
	// ino = &inode{
	// handle: h,
	// 	volume: fi.VolumeSerialNumber,
	// 	index:  uint64(fi.FileIndexHigh)<<32 | uint64(fi.FileIndexLow),
	// }

	bufsize :: 65536
	// op:      Create | Write | Remove | Rename | Chmod,

	ov := windows.OVERLAPPED {
		hEvent = windows.CreateEventW(nil, false, false, nil),
	}
	if ov.hEvent == nil {
		log.error("failed to create event")
		return Windows_Entry{}
	}


	return Windows_Entry {
		handle = handle,
		path = path,
		recursive = true,
		buf = make([]byte, bufsize),
		ov = ov,
	}
}

windows_entry_destroy :: proc(entry: ^Windows_Entry) {
	delete(entry.buf)
}

File_Notify_Change :: bit_set[File_Notify_Change_Event;windows.DWORD]
File_Notify_Change_Event :: enum windows.DWORD {
	FILE_NOTIFY_CHANGE_FILE_NAME,
	FILE_NOTIFY_CHANGE_DIR_NAME,
	FILE_NOTIFY_CHANGE_ATTRIBUTES,
	FILE_NOTIFY_CHANGE_SIZE,
	FILE_NOTIFY_CHANGE_LAST_WRITE,
	FILE_NOTIFY_CHANGE_SECURITY,
}

File_Action :: enum windows.DWORD {
	None                         = 0,
	FILE_ACTION_ADDED            = 0x00000001,
	FILE_ACTION_REMOVED          = 0x00000002,
	FILE_ACTION_MODIFIED         = 0x00000003,
	FILE_ACTION_RENAMED_OLD_NAME = 0x00000004,
	FILE_ACTION_RENAMED_NEW_NAME = 0x00000005,
}

_watch_dir :: proc(entry: ^Windows_Entry) {
	entry.ov = windows.OVERLAPPED {
		hEvent = entry.ov.hEvent,
	}

	mask: File_Notify_Change = {
		.FILE_NOTIFY_CHANGE_FILE_NAME,
		.FILE_NOTIFY_CHANGE_DIR_NAME,
		.FILE_NOTIFY_CHANGE_LAST_WRITE,
		.FILE_NOTIFY_CHANGE_SIZE,
		.FILE_NOTIFY_CHANGE_ATTRIBUTES,
	}

	bytes_returned: windows.LPDWORD
	if !windows.ReadDirectoryChangesW(
		entry.handle,
		&entry.buf[0],
		windows.DWORD(len(entry.buf)),
		entry.recursive,
		transmute(windows.DWORD)File_Notify_Change(mask),
		bytes_returned,
		&entry.ov,
		nil,
	) {
		err := os.get_last_error()
		if platform_err, ok := err.(os.Platform_Error); ok {
			// TODO
			log.error(platform_err)
		}
		log.error("failed to read directory changes", err)
	}
}

_handle_events :: proc(entry: ^Windows_Entry, msg_buf: ^Msg_Buffer, msg_queue: ^queue.Queue(Msg)) {
	res := windows.WaitForSingleObject(entry.ov.hEvent, 0)
	if res == windows.WAIT_OBJECT_0 {
		bytes_transferred: windows.DWORD
		if !windows.GetOverlappedResult(entry.handle, &entry.ov, &bytes_transferred, false) {
			log.warn("no overlapped result")
			return
		}

		offset: windows.DWORD = 0
		for {
			info := cast(^windows.FILE_NOTIFY_INFORMATION)&entry.buf[offset]
			action := cast(File_Action)info.action
			if action == .None {
				break
			}
			raw := transmute(cstring16)&info.file_name[0]
			path, err := windows.wstring_to_utf8(raw, int(info.file_name_length / 2))
			if err != nil {
				log.error("failed to allocate file path")
			}
			path_norm, _ := filepath.to_slash(path)
			file_path := strings.clone(path_norm)
			log.info("path", file_path, info.file_name_length)

			switch action {
			case .None:
				panic("none case should have be handled before")
			case .FILE_ACTION_ADDED:
				_push_message(msg_buf, Msg_Created{path = file_path})
			case .FILE_ACTION_REMOVED:
				_push_message(msg_buf, Msg_Removed{path = file_path})
			case .FILE_ACTION_MODIFIED:
				_push_message(msg_buf, Msg_Modified{path = file_path})
			case .FILE_ACTION_RENAMED_OLD_NAME:
				_push_message(msg_buf, Msg_Modified{path = file_path})
			case .FILE_ACTION_RENAMED_NEW_NAME:
				_push_message(msg_buf, Msg_Modified{path = file_path})
			}

			if info.next_entry_offset == 0 {
				break
			}
			offset += info.next_entry_offset
		}

		_watch_dir(entry)
	} else {
		if res == windows.WAIT_TIMEOUT {
			return
		}
		log.error("err in WaitForSingleObject")
	}
}

_watch_worker :: proc(t: ^thread.Thread) {
	thread_data := cast(^Worker_Data)t.data
	channel := thread_data.chan

	msg_queue := queue.Queue(Msg){}
	queue.init(&msg_queue)
	defer queue.destroy(&msg_queue)
	log.debug(thread_data.path)

	fw_entry := windows_entry(thread_data.path)
	_watch_dir(&fw_entry)
	defer windows.CloseHandle(fw_entry.ov.hEvent)
	defer windows.CloseHandle(fw_entry.handle)

	msg_buf := Msg_Buffer {
		debounce_time = thread_data.throttle_time,
	}
	// TODO: destroy proc
	defer delete(msg_buf.messages)

	chan.send(thread_data.status_chan, true)

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
				continue
			}
			queue.pop_front(&msg_queue)
		}

		// TODO
		when ODIN_OS == .Windows {
			_handle_events(&fw_entry, &msg_buf, &msg_queue)
		} else {
			panic("only Windows is supported at the moment")
		}
	}
	log.debug("stopping watcher thread")
}

