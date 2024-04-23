//+build windows
package win32ext

import "core:sys/windows"

import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"
import "core:unicode"
import "core:mem"
import "core:os"
import "core:c/libc"


get_sys_clipboard_utf8 :: proc(allocator := context.allocator) -> string {
    context.allocator = allocator;
    open_result := OpenClipboard(nil);
    assert(open_result != false, "Win32 OpenClipboard failed");
    
    data := GetClipboardData(CF_UNICODETEXT);

    if data == nil {
        CloseClipboard();
        return strings.clone("");
    }

    text_data := cast([^]u16)GlobalLock(cast(windows.HGLOBAL)data);
    
    if text_data == nil {
        CloseClipboard();
        return strings.clone("");
    }
    
    u16_len := 0;
    for text_data[u16_len] != 0 do u16_len += 1;

    byte_buffer := make([]byte, u16_len);
    
    len := utf16.decode_to_utf8(byte_buffer, mem.slice_ptr(text_data, u16_len));

    result := string(byte_buffer);

    GlobalUnlock(cast(windows.HGLOBAL)data);
    CloseClipboard();

    return result;
}

open_in_explorer :: proc(dir : string) {
    context.allocator = context.temp_allocator;
    ShellExecute(nil, "explore", nil, nil, strings.clone_to_cstring(dir), windows.SW_SHOWDEFAULT);
}

truncate :: proc(handle : os.Handle, new_end : int) {
    win32_handle := cast(windows.HANDLE)handle;
    windows.SetFilePointer(win32_handle, 0, nil, windows.FILE_BEGIN);
    windows.SetEndOfFile(win32_handle);
}