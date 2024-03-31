package osext

import "win32"
import "linux"

import "core:strings"
import "core:builtin"
import "core:c"
import "core:c/libc"



when ODIN_OS == .Windows {
    get_sys_clipboard_utf8 :: win32.get_sys_clipboard_utf8;
    open_in_explorer :: win32.open_in_explorer;
} else when ODIN_OS == .Linux {
    get_sys_clipboard_utf8 :: linux.get_sys_clipboard_utf8;
    open_in_explorer :: linux.open_in_explorer;
} else {
    #assert(false, "Unsupported OS");
}