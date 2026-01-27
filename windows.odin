#+build windows
package dirwatch

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

Worker_State :: struct {
	msg_buf:   Msg_Buffer,
	entry:     Windows_Entry,
	iocp:      windows.HANDLE,
	ov:        windows.OVERLAPPED,
	recursive: bool,
	path:      string,
	mask:      windows.UINT64,
	buf:       []byte,
}

@(private)
Windows_Entry :: struct #align (4) {
	handle: windows.HANDLE,
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

_watch_dir :: proc(state: ^Worker_State) {
	state.ov = windows.OVERLAPPED{}

	mask: File_Notify_Change = {
		.FILE_NOTIFY_CHANGE_FILE_NAME,
		.FILE_NOTIFY_CHANGE_DIR_NAME,
		.FILE_NOTIFY_CHANGE_LAST_WRITE,
		.FILE_NOTIFY_CHANGE_SIZE,
		.FILE_NOTIFY_CHANGE_ATTRIBUTES,
	}

	path_c16 := windows.utf8_to_wstring_alloc(state.path)
	dir := windows.CreateFileW(
		path_c16,
		windows.FILE_LIST_DIRECTORY,
		windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
		nil,
	)

	state.iocp = windows.CreateIoCompletionPort(windows.INVALID_HANDLE_VALUE, nil, 0, 0)
	windows.CreateIoCompletionPort(dir, state.iocp, windows.ULONG_PTR(uintptr(dir)), 0)

	bytes_returned: windows.LPDWORD
	if !windows.ReadDirectoryChangesExW(
		dir,
		&state.buf[0],
		windows.DWORD(len(state.buf)),
		windows.BOOL(state.recursive),
		transmute(windows.DWORD)File_Notify_Change(mask),
		nil,
		&state.ov,
		nil,
		.ReadDirectoryNotifyExtendedInformation,
	) {
		err := os.get_last_error()
		if platform_err, ok := err.(os.Platform_Error); ok {
			// TODO
			log.error(platform_err)
		}
		log.error("failed to read directory changes", err)
	}
}

@(private)
worker_setup :: proc(data: ^Worker_Data) -> (state: Worker_State, ok: bool) {
	BUF_SIZE :: 65536

	state.buf = make([]byte, BUF_SIZE)
	state.path = data.path
	state.recursive = data.recursive
	_watch_dir(&state)

	return state, true
}

@(private)
worker_handle_events :: proc(state: ^Worker_State) {
	entry := state.entry
	bytes: windows.DWORD
	key: windows.ULONG_PTR
	complete_ov: ^windows.OVERLAPPED
	if windows.GetQueuedCompletionStatus(state.iocp, &bytes, &key, &complete_ov, 10) {
		offset: windows.DWORD = 0
		for {
			info := cast(^windows.FILE_NOTIFY_EXTENDED_INFORMATION)&state.buf[offset]
			action := cast(File_Action)info.Action
			if action == .None {
				break
			}
			raw := transmute(windows.wstring)&info.FileName[0]
			path, err := windows.wstring_to_utf8(raw, int(info.FileNameLength / 2))
			if err != nil {
				log.error("failed to allocate file path")
			}
			path_norm, _ := filepath.to_slash(path)
			file_path := strings.clone(path_norm)

			target: Target = .File
			if (info.FileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
				target = .Dir
			}

			switch action {
			case .None:
				panic("none case should have be handled before")
			case .FILE_ACTION_ADDED:
				_push_message(&state.msg_buf, target, Ev_Created{path = file_path})
			case .FILE_ACTION_REMOVED:
				_push_message(&state.msg_buf, target, Ev_Removed{path = file_path})
			case .FILE_ACTION_MODIFIED:
				_push_message(&state.msg_buf, target, Ev_Modified{path = file_path})
			case .FILE_ACTION_RENAMED_OLD_NAME:
				_push_message(&state.msg_buf, target, Ev_Modified{path = file_path})
			case .FILE_ACTION_RENAMED_NEW_NAME:
				_push_message(&state.msg_buf, target, Ev_Modified{path = file_path})
			}

			if info.NextEntryOffset == 0 {
				break
			}
			offset += info.NextEntryOffset
		}

		_watch_dir(state)
	}
}

