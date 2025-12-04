package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Constants
LINENOISE_DEFAULT_HISTORY_MAX_LEN :: 100
LINENOISE_MAX_LINE :: 4096

// Key Codes
KEY_NULL :: 0
CTRL_A :: 1
CTRL_B :: 2
CTRL_C :: 3
CTRL_D :: 4
CTRL_E :: 5
CTRL_F :: 6
CTRL_H :: 8
TAB :: 9
CTRL_K :: 11
CTRL_L :: 12
ENTER :: 13
CTRL_N :: 14
CTRL_P :: 16
CTRL_T :: 20
CTRL_U :: 21
CTRL_W :: 23
ESC :: 27
BACKSPACE :: 127

// Structs
State :: struct {
	in_completion:  bool,
	completion_idx: int,
	ifd:            c.int,
	ofd:            c.int,
	buf:            [dynamic]byte,
	buf_ptr:        [^]byte,
	buflen:         int,
	prompt:         string,
	plen:           int,
	pos:            int,
	oldpos:         int,
	len:            int,
	cols:           int,
	oldrows:        int,
	history_index:  int,
}

Completions :: struct {
	len:  int,
	cvec: [dynamic]string,
}

// Callbacks
CompletionCallback :: proc(buf: string, lc: ^Completions)
HintsCallback :: proc(buf: string, color: ^int, bold: ^int) -> string
FreeHintsCallback :: proc(hint: string)

// Globals
orig_termios: posix.termios
rawmode: bool
mlmode: bool
history_max_len: int = LINENOISE_DEFAULT_HISTORY_MAX_LEN
history: [dynamic]string
completion_callback: CompletionCallback
hints_callback: HintsCallback
free_hints_callback: FreeHintsCallback

// Error definitions
Error :: enum {
	None,
	ReadError,
	WriteError,
	UnsupportedTerm,
	RawModeError,
}

// Missing POSIX/System definitions for macOS
foreign import libc "system:c"

foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

winsize :: struct {
	ws_row:    c.ushort,
	ws_col:    c.ushort,
	ws_xpixel: c.ushort,
	ws_ypixel: c.ushort,
}

TIOCGWINSZ :: 0x40087468
TCSAFLUSH :: 2

// Helper to cast string literal to byte slice for raw_data
str_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// Helper to check unsupported terminals
isUnsupportedTerm :: proc() -> bool {
	term := os.get_env("TERM")
	if term == "" {
		return false
	}
	unsupported := []string{"dumb", "cons25", "emacs"}
	for t in unsupported {
		if strings.compare(term, t) == 0 {
			return true
		}
	}
	return false
}

enableRawMode :: proc(fd: c.int) -> Error {
	if !posix.isatty(posix.FD(fd)) {
		return .UnsupportedTerm
	}

	if posix.tcgetattr(posix.FD(fd), &orig_termios) == posix.result(-1) {
		return .RawModeError
	}

	raw := orig_termios

	// Use transmute to do bitwise operations on flags
	iflag := transmute(c.ulong)raw.c_iflag
	iflag &= ~c.ulong(posix.BRKINT | posix.ICRNL | posix.INPCK | posix.ISTRIP | posix.IXON)
	raw.c_iflag = transmute(type_of(raw.c_iflag))iflag

	oflag := transmute(c.ulong)raw.c_oflag
	oflag &= ~c.ulong(posix.OPOST)
	raw.c_oflag = transmute(type_of(raw.c_oflag))oflag

	cflag := transmute(c.ulong)raw.c_cflag
	cflag |= c.ulong(posix.CS8)
	raw.c_cflag = transmute(type_of(raw.c_cflag))cflag

	lflag := transmute(c.ulong)raw.c_lflag
	lflag &= ~c.ulong(posix.ECHO | posix.ICANON | posix.IEXTEN | posix.ISIG)
	raw.c_lflag = transmute(type_of(raw.c_lflag))lflag

	// Fix c_cc indexing
	raw.c_cc[posix.Control_Char(posix.VMIN)] = 1
	raw.c_cc[posix.Control_Char(posix.VTIME)] = 0

	if posix.tcsetattr(posix.FD(fd), posix.TC_Optional_Action(TCSAFLUSH), &raw) < posix.result(0) {
		return .RawModeError
	}

	rawmode = true
	return .None
}

disableRawMode :: proc(fd: c.int) {
	if rawmode &&
	   posix.tcsetattr(posix.FD(fd), posix.TC_Optional_Action(TCSAFLUSH), &orig_termios) !=
		   posix.result(-1) {
		rawmode = false
	}
}

getCursorPosition :: proc(ifd: c.int, ofd: c.int) -> (int, int) {
	buf: [32]byte
	i: int = 0

	if posix.write(posix.FD(ofd), raw_data(str_bytes("\x1b[6n")), 4) != 4 {
		return -1, -1
	}

	for i < len(buf) - 1 {
		if posix.read(posix.FD(ifd), &buf[i], 1) != 1 {
			break
		}
		if buf[i] == 'R' {
			break
		}
		i += 1
	}
	buf[i] = 0

	if buf[0] != 27 || buf[1] != '[' {
		return -1, -1
	}

	s := string(buf[2:i])
	parts := strings.split(s, ";")
	defer delete(parts)

	if len(parts) != 2 {
		return -1, -1
	}

	rows := parseInt(parts[0])
	cols := parseInt(parts[1])
	return rows, cols
}

parseInt :: proc(s: string) -> int {
	res := 0
	for c in s {
		if c >= '0' && c <= '9' {
			res = res * 10 + int(c - '0')
		}
	}
	return res
}

getCursorPosition_impl :: proc(ifd: c.int, ofd: c.int) -> (int, int) {
	buf: [32]byte
	i: int = 0

	if posix.write(posix.FD(ofd), raw_data(str_bytes("\x1b[6n")), 4) != 4 {
		return -1, -1
	}

	for i < len(buf) - 1 {
		if posix.read(posix.FD(ifd), &buf[i], 1) != 1 {
			break
		}
		if buf[i] == 'R' {
			break
		}
		i += 1
	}
	buf[i] = 0

	if buf[0] != 27 || buf[1] != '[' {
		return -1, -1
	}

	s := string(buf[2:i])
	parts := strings.split(s, ";")
	defer delete(parts)

	if len(parts) != 2 {
		return -1, -1
	}

	rows := parseInt(parts[0])
	cols := parseInt(parts[1])
	return rows, cols
}

getColumns :: proc(ifd: c.int, ofd: c.int) -> int {
	ws: winsize

	if ioctl(1, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0 {
		start_rows, start_cols := getCursorPosition_impl(ifd, ofd)
		if start_cols == -1 {
			return 80
		}

		if posix.write(posix.FD(ofd), raw_data(str_bytes("\x1b[999C")), 6) != 6 {
			return 80
		}

		cols_rows, cols_cols := getCursorPosition_impl(ifd, ofd)
		if cols_cols == -1 {
			return 80
		}

		if cols_cols > start_cols {
			// Restore position
			seq := fmt.tprintf("\x1b[%dD", cols_cols - start_cols)
			posix.write(posix.FD(ofd), raw_data(transmute([]byte)seq), c.size_t(len(seq)))
		}

		return cols_cols
	} else {
		return int(ws.ws_col)
	}
}

// Line Editing

linenoiseEditStart :: proc(
	l: ^State,
	stdin_fd: c.int,
	stdout_fd: c.int,
	buf: [^]byte,
	buflen: int,
	prompt: string,
) -> int {
	l.in_completion = false
	l.ifd = stdin_fd != -1 ? stdin_fd : c.int(posix.STDIN_FILENO)
	l.ofd = stdout_fd != -1 ? stdout_fd : c.int(posix.STDOUT_FILENO)
	l.buf_ptr = buf
	l.buflen = buflen
	l.prompt = prompt
	l.plen = len(prompt)
	l.oldpos = 0
	l.pos = 0
	l.len = 0

	if enableRawMode(l.ifd) != .None {
		return -1
	}

	l.cols = getColumns(l.ifd, l.ofd)
	l.oldrows = 0
	l.history_index = 0

	// Buffer starts empty
	l.buf_ptr[0] = 0
	l.buflen -= 1 // Make sure there is always space for nulterm

	if !posix.isatty(posix.FD(l.ifd)) {
		return 0
	}

	// History add empty string (current buffer)
	linenoiseHistoryAdd("")

	if posix.write(posix.FD(l.ofd), raw_data(str_bytes(prompt)), c.size_t(l.plen)) == -1 {
		return -1
	}

	return 0
}

linenoiseEditStop :: proc(l: ^State) {
	if !posix.isatty(posix.FD(l.ifd)) {
		return
	}
	disableRawMode(l.ifd)
	fmt.println()
}

refreshLine :: proc(l: ^State) {
	// Simple single line refresh for now
	// TODO: Multi-line support

	ab: [dynamic]byte
	defer delete(ab)

	// Cursor to left edge
	append(&ab, '\r')

	// Write prompt and buffer
	append(&ab, ..transmute([]byte)l.prompt)

	// TODO: maskmode support
	// Write buffer content
	// We need to construct a slice from buf_ptr and len
	buf_slice := l.buf_ptr[:l.len]
	append(&ab, ..buf_slice)

	// Erase to right
	append(&ab, ..str_bytes("\x1b[0K"))

	// Move cursor to original position
	cursor_seq := fmt.tprintf("\r\x1b[%dC", l.pos + l.plen)
	append(&ab, ..transmute([]byte)cursor_seq)

	posix.write(posix.FD(l.ofd), raw_data(ab), c.size_t(len(ab)))
}

linenoiseEditInsert :: proc(l: ^State, c: byte) -> int {
	if l.len < l.buflen {
		if l.len == l.pos {
			l.buf_ptr[l.pos] = c
			l.pos += 1
			l.len += 1
			l.buf_ptr[l.len] = 0

			// Trivial case optimization could go here
			refreshLine(l)
		} else {
			// memmove
			for i := l.len; i > l.pos; i -= 1 {
				l.buf_ptr[i] = l.buf_ptr[i - 1]
			}
			l.buf_ptr[l.pos] = c
			l.len += 1
			l.pos += 1
			l.buf_ptr[l.len] = 0
			refreshLine(l)
		}
	}
	return 0
}

linenoiseEditMoveLeft :: proc(l: ^State) {
	if l.pos > 0 {
		l.pos -= 1
		refreshLine(l)
	}
}

linenoiseEditMoveRight :: proc(l: ^State) {
	if l.pos != l.len {
		l.pos += 1
		refreshLine(l)
	}
}

linenoiseEditMoveHome :: proc(l: ^State) {
	if l.pos != 0 {
		l.pos = 0
		refreshLine(l)
	}
}

linenoiseEditMoveEnd :: proc(l: ^State) {
	if l.pos != l.len {
		l.pos = l.len
		refreshLine(l)
	}
}

linenoiseEditDelete :: proc(l: ^State) {
	if l.len > 0 && l.pos < l.len {
		// memmove
		for i := l.pos; i < l.len - 1; i += 1 {
			l.buf_ptr[i] = l.buf_ptr[i + 1]
		}
		l.len -= 1
		l.buf_ptr[l.len] = 0
		refreshLine(l)
	}
}

linenoiseEditBackspace :: proc(l: ^State) {
	if l.pos > 0 && l.len > 0 {
		// memmove
		for i := l.pos - 1; i < l.len - 1; i += 1 {
			l.buf_ptr[i] = l.buf_ptr[i + 1]
		}
		l.pos -= 1
		l.len -= 1
		l.buf_ptr[l.len] = 0
		refreshLine(l)
	}
}

HistoryDir :: enum {
	Next,
	Prev,
}

linenoiseEditHistoryNext :: proc(l: ^State, dir: HistoryDir) {
	if len(history) > 1 {
		// Update the current history entry before to
		// overwrite it with the next one.
		delete(history[len(history) - 1 - l.history_index])
		history[len(history) - 1 - l.history_index] = strings.clone_from_bytes(l.buf_ptr[:l.len])

		// Show the new entry
		l.history_index += (dir == .Prev) ? 1 : -1
		if l.history_index < 0 {
			l.history_index = 0
			return
		} else if l.history_index >= len(history) {
			l.history_index = len(history) - 1
			return
		}

		entry := history[len(history) - 1 - l.history_index]
		// Copy entry to buf
		if len(entry) >= l.buflen {
			// Truncate if too long? Or just copy what fits
			// linenoise.c uses strncpy which truncates and might not null-terminate if full
			// We should probably just copy what fits
			copy(l.buf_ptr[:l.buflen - 1], entry)
			l.len = l.buflen - 1
		} else {
			copy(l.buf_ptr[:len(entry)], entry)
			l.len = len(entry)
		}
		l.buf_ptr[l.len] = 0
		l.pos = l.len
		refreshLine(l)
	}
}

linenoiseEditFeed :: proc(l: ^State) -> string {
	if !posix.isatty(posix.FD(l.ifd)) {
		// TODO: NoTTY handling
		return ""
	}

	c: byte
	nread := posix.read(posix.FD(l.ifd), &c, 1)
	if nread <= 0 {
		return ""
	}

	// TODO: Completion handling

	switch c {
	case ENTER:
		if len(history) > 0 {
			delete(history[len(history) - 1])
			ordered_remove(&history, len(history) - 1)
		}
		return strings.clone_from_bytes(l.buf_ptr[:l.len])
	case CTRL_C:
		return "" // TODO: errno EAGAIN
	case BACKSPACE, 8:
		linenoiseEditBackspace(l)
	case CTRL_D:
		if l.len > 0 {
			linenoiseEditDelete(l)
		} else {
			if len(history) > 0 {
				delete(history[len(history) - 1])
				ordered_remove(&history, len(history) - 1)
			}
			return "" // EOF
		}
	case CTRL_T:
		if l.pos > 0 && l.pos < l.len {
			aux := l.buf_ptr[l.pos - 1]
			l.buf_ptr[l.pos - 1] = l.buf_ptr[l.pos]
			l.buf_ptr[l.pos] = aux
			if l.pos != l.len - 1 {
				l.pos += 1
			}
			refreshLine(l)
		}
	case CTRL_B:
		linenoiseEditMoveLeft(l)
	case CTRL_F:
		linenoiseEditMoveRight(l)
	case CTRL_P:
		linenoiseEditHistoryNext(l, .Prev)
	case CTRL_N:
		linenoiseEditHistoryNext(l, .Next)
	case ESC:
		seq: [3]byte
		if posix.read(posix.FD(l.ifd), &seq[0], 1) == -1 {return "more"}
		if posix.read(posix.FD(l.ifd), &seq[1], 1) == -1 {return "more"}

		if seq[0] == '[' {
			if seq[1] >= '0' && seq[1] <= '9' {
				if posix.read(posix.FD(l.ifd), &seq[2], 1) == -1 {return "more"}
				if seq[2] == '~' {
					switch seq[1] {
					case '3':
						linenoiseEditDelete(l)
					}
				}
			} else {
				switch seq[1] {
				case 'A':
					// Up
					linenoiseEditHistoryNext(l, .Prev)
				case 'B':
					// Down
					linenoiseEditHistoryNext(l, .Next)
				case 'C':
					linenoiseEditMoveRight(l)
				case 'D':
					linenoiseEditMoveLeft(l)
				case 'H':
					linenoiseEditMoveHome(l)
				case 'F':
					linenoiseEditMoveEnd(l)
				}
			}
		} else if seq[0] == 'O' {
			switch seq[1] {
			case 'H':
				linenoiseEditMoveHome(l)
			case 'F':
				linenoiseEditMoveEnd(l)
			}
		}
	case CTRL_U:
		l.buf_ptr[0] = 0
		l.pos = 0
		l.len = 0
		refreshLine(l)
	case CTRL_K:
		l.buf_ptr[l.pos] = 0
		l.len = l.pos
		refreshLine(l)
	case CTRL_A:
		linenoiseEditMoveHome(l)
	case CTRL_E:
		linenoiseEditMoveEnd(l)
	case CTRL_L:
		// clear screen
		refreshLine(l)
	case CTRL_W:
	// delete prev word
	case:
		linenoiseEditInsert(l, c)
	}

	return "more" // Special value to indicate more editing needed
}

linenoise :: proc(prompt: string) -> string {
	buf: [LINENOISE_MAX_LINE]byte
	state: State

	if linenoiseEditStart(&state, -1, -1, raw_data(buf[:]), len(buf), prompt) == -1 {
		return ""
	}

	for {
		res := linenoiseEditFeed(&state)
		if res != "more" {
			linenoiseEditStop(&state)
			return res
		}
	}
	return ""
}

// History API

linenoiseHistoryAdd :: proc(line: string) -> int {
	if history_max_len == 0 {
		return 0
	}

	if line == "" {
		return 0
	}

	// Don't add duplicated lines
	if len(history) > 0 && history[len(history) - 1] == line {
		return 0
	}

	if len(history) == history_max_len {
		delete(history[0])
		ordered_remove(&history, 0)
	}

	append(&history, strings.clone(line))
	return 1
}

linenoiseHistorySetMaxLen :: proc(l: int) -> int {
	if l < 1 {
		return 0
	}
	history_max_len = l
	if len(history) > history_max_len {
		// Remove oldest
		to_remove := len(history) - history_max_len
		for i := 0; i < to_remove; i += 1 {
			delete(history[0])
			ordered_remove(&history, 0)
		}
	}
	return 1
}

linenoiseHistorySave :: proc(filename: string) -> int {
	// TODO: umask handling if needed

	f, err := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if err != 0 {
		return -1
	}
	defer os.close(f)

	for line in history {
		os.write_string(f, line)
		os.write_string(f, "\n")
	}
	return 0
}

linenoiseHistoryLoad :: proc(filename: string) -> int {
	data, ok := os.read_entire_file(filename)
	if !ok {
		return -1
	}
	defer delete(data)

	s := string(data)
	lines := strings.split(s, "\n")
	defer delete(lines)

	for line in lines {
		// Remove \r if present
		l := strings.trim_right(line, "\r")
		if l != "" {
			linenoiseHistoryAdd(l)
		}
	}
	return 0
}
