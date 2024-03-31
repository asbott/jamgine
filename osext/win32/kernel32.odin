//+build windows
package win32ext

import "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"
foreign kernel32 {
	GlobalLock :: proc "stdcall" (mem : windows.HGLOBAL) -> windows.LPVOID ---
    GlobalUnlock :: proc "stdcall" (mem : windows.HGLOBAL) -> windows.BOOL ---    
}