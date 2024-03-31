//+build windows
package win32ext

import "core:sys/windows"

foreign import user32 "system:user32.lib"
foreign user32 {
	GetClipboardData :: proc "stdcall" (format : windows.UINT) -> windows.HANDLE ---
    SetClipboardData :: proc "stdcall" (format : windows.UINT, mem : windows.HANDLE) -> windows.HANDLE ---
    OpenClipboard    :: proc "stdcall" (new_owner : windows.HWND) -> windows.BOOL ---
    CloseClipboard   :: proc "stdcall" () -> windows.BOOL ---
}
CF_TEXT         :: 1
CF_BITMAP       :: 2
CF_METAFILEPICT :: 3
CF_SYLK         :: 4
CF_DIF          :: 5
CF_TIFF         :: 6
CF_OEMTEXT      :: 7
CF_DIB          :: 8
CF_PALETTE      :: 9
CF_PENDATA      :: 10
CF_RIFF         :: 11
CF_WAVE         :: 12
CF_UNICODETEXT  :: 13
CF_ENHMETAFILE  :: 14
CF_HDROP        :: 15
CF_LOCALE       :: 16
CF_DIBV5        :: 17