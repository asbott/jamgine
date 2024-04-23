//+build linux
package linuxext

import "core:sys/linux"
import "core:os"

truncate :: proc(handle : os.Handle, new_end : int) {
    // #Linux
    // Double check this is how it works in linux backend
    linux_handle := cast(windows.HANDLE)handle;

    linux.ftruncate(linux_handle, cast(i32)new_end);
}