#+build !windows
package intercept_cli

setup_utf8_console :: proc() {
	// macOS / Linux terminals are UTF-8 by default — nothing to do.
}
