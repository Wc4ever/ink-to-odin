#+build windows
package intercept_cli

import win32 "core:sys/windows"

setup_utf8_console :: proc() {
	// Without this, em-dashes / curly quotes from the ink script come out
	// as garbage (UTF-8 bytes interpreted as the local ANSI code page).
	win32.SetConsoleOutputCP(.UTF8)
}
