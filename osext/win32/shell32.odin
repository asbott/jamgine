//+build windows
package win32ext

import "core:sys/windows"

foreign import shell32 "system:shell32.lib"
foreign shell32 {
	ShellExecuteA :: proc "stdcall" (
        hwnd : windows.HWND, 
        lpOperation : windows.LPCSTR, 
        lpFile : windows.LPCSTR, 
        lpParameters : windows.LPCSTR, 
        lpDirectory : windows.LPCSTR, 
        nShowCmd : windows.INT
    ) -> windows.HINSTANCE ---
}
ShellExecute :: ShellExecuteA;