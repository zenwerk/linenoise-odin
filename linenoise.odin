package linenoise

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

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
maskmode: bool
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

// Helper to calculate column width of a string
getStrWidth :: proc(s: string) -> int {
	width := 0
	for r in s {
		// Simple check for wide characters (CJK, etc.)
		// This is a simplified version. For full support we might need a wcwidth equivalent.
		// For now, we assume standard wide characters.
		if r >= 0x1100 {
			width += 2
		} else {
			width += 1
		}
	}
	return width
}

// Helper to calculate column width of a byte slice up to a certain length
getByteSliceWidth :: proc(b: []byte) -> int {
	return getStrWidth(string(b))
}

linenoiseBeep :: proc() {
	posix.write(posix.STDERR_FILENO, raw_data(str_bytes("\x07")), 1)
}

linenoiseClearScreen :: proc() {
	if posix.write(posix.STDOUT_FILENO, raw_data(str_bytes("\x1b[H\x1b[2J")), 7) <= 0 {
		// nothing to do on error
	}
}

linenoiseSetCompletionCallback :: proc(fn: CompletionCallback) {
	completion_callback = fn
}

linenoiseAddCompletion :: proc(lc: ^Completions, str: string) {
	append(&lc.cvec, strings.clone(str))
	lc.len = len(lc.cvec)
}

freeCompletions :: proc(lc: ^Completions) {
	for s in lc.cvec {
		delete(s)
	}
	delete(lc.cvec)
	lc.len = 0
}

linenoiseSetHintsCallback :: proc(fn: HintsCallback) {
	hints_callback = fn
}

linenoiseSetFreeHintsCallback :: proc(fn: FreeHintsCallback) {
	free_hints_callback = fn
}

linenoiseMaskModeEnable :: proc() {
	maskmode = true
}

linenoiseMaskModeDisable :: proc() {
	maskmode = false
}

linenoiseSetMultiLine :: proc(ml: bool) {
	mlmode = ml
}

// Append Buffer
abuf :: struct {
	b: [dynamic]byte,
}

abAppend :: proc(ab: ^abuf, s: string) {
	append(&ab.b, ..transmute([]byte)s)
}

abAppendBytes :: proc(ab: ^abuf, b: []byte) {
	append(&ab.b, ..b)
}

abFree :: proc(ab: ^abuf) {
	delete(ab.b)
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
	l.plen = getStrWidth(prompt)
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

refreshShowHints :: proc(ab: ^abuf, l: ^State, pwidth: int) {
	bwidth := getByteSliceWidth(l.buf_ptr[:l.len])
	if hints_callback != nil && pwidth + bwidth < l.cols {
		color: int = -1
		bold: int = 0
		buf_str := string(l.buf_ptr[:l.len])
		hint := hints_callback(buf_str, &color, &bold)
		if hint != "" {
			hintwidth := getStrWidth(hint)
			hintmaxwidth := l.cols - (pwidth + bwidth)

			print_hint := hint
			if hintwidth > hintmaxwidth {
				w := 0
				end_idx := 0
				for r in hint {
					rw := 1
					if r >= 0x1100 {rw = 2}
					if w + rw > hintmaxwidth {break}
					w += rw
					end_idx += utf8.rune_size(r)
				}
				print_hint = hint[:end_idx]
			}

			if bold == 1 && color == -1 {
				color = 37
			}

			if color != -1 || bold != 0 {
				seq := fmt.tprintf("\x1b[%d;%d;49m", bold, color)
				abAppend(ab, seq)
			}

			abAppend(ab, print_hint)

			if color != -1 || bold != 0 {
				abAppend(ab, "\x1b[0m")
			}

			if free_hints_callback != nil {
				free_hints_callback(hint)
			}
		}
	}
}

refreshSingleLine :: proc(l: ^State) {
	ab: abuf
	defer abFree(&ab)

	pwidth := getStrWidth(l.prompt)
	cwidth := getByteSliceWidth(l.buf_ptr[:l.pos])
	// bwidth := getByteSliceWidth(l.buf_ptr[:l.len]) // Not strictly needed if we iterate

	buf_slice := l.buf_ptr[:l.len]

	// Calculate scrolling
	buf_idx := 0
	current_skip_width := 0
	target_skip_width := pwidth + cwidth - l.cols + 1

	if target_skip_width > 0 {
		offset := 0
		for offset < l.len {
			if current_skip_width >= target_skip_width {
				break
			}

			b := buf_slice[offset]
			rune_len := 1
			if b & 0xE0 ==
			   0xC0 {rune_len = 2} else if b & 0xF0 == 0xE0 {rune_len = 3} else if b & 0xF8 == 0xF0 {rune_len = 4}

			w := 1
			if rune_len > 1 {
				r, _ := utf8.decode_rune(buf_slice[offset:min(offset + rune_len, l.len)])
				if r >= 0x1100 {w = 2}
			}

			current_skip_width += w
			offset += rune_len
		}
		buf_idx = offset
	}

	// Calculate end_byte
	end_byte := buf_idx
	current_print_width := 0
	max_print_width := l.cols - pwidth

	for end_byte < l.len {
		b := buf_slice[end_byte]
		rune_len := 1
		if b & 0xE0 ==
		   0xC0 {rune_len = 2} else if b & 0xF0 == 0xE0 {rune_len = 3} else if b & 0xF8 == 0xF0 {rune_len = 4}

		w := 1
		if rune_len > 1 {
			r, _ := utf8.decode_rune(buf_slice[end_byte:min(end_byte + rune_len, l.len)])
			if r >= 0x1100 {w = 2}
		}

		if current_print_width + w > max_print_width {
			break
		}

		current_print_width += w
		end_byte += rune_len
	}

	// Cursor to left edge
	abAppend(&ab, "\r")

	// Write prompt
	abAppend(&ab, l.prompt)

	// Write buffer content
	if maskmode {
		for i := 0; i < current_print_width; i += 1 {
			abAppend(&ab, "*")
		}
	} else {
		abAppendBytes(&ab, buf_slice[buf_idx:end_byte])
	}

	refreshShowHints(&ab, l, pwidth)

	// Erase to right
	abAppend(&ab, "\x1b[0K")

	// Move cursor to original position
	// Cursor pos is pwidth + (cwidth - current_skip_width)
	cursor_visual_pos := pwidth + cwidth - current_skip_width
	cursor_seq := fmt.tprintf("\r\x1b[%dC", cursor_visual_pos)
	abAppend(&ab, cursor_seq)

	posix.write(posix.FD(l.ofd), raw_data(ab.b), c.size_t(len(ab.b)))
}

refreshMultiLine :: proc(l: ^State) {
	pwidth := getStrWidth(l.prompt)
	cwidth := getByteSliceWidth(l.buf_ptr[:l.pos])
	bwidth := getByteSliceWidth(l.buf_ptr[:l.len])

	rows := (pwidth + bwidth + l.cols - 1) / l.cols
	rpos := (pwidth + l.oldpos + l.cols) / l.cols // l.oldpos is now old_cwidth
	old_rows := l.oldrows

	l.oldrows = rows

	ab: abuf
	defer abFree(&ab)

	// First step: clear all the lines used before.
	if old_rows - rpos > 0 {
		seq := fmt.tprintf("\x1b[%dB", old_rows - rpos)
		abAppend(&ab, seq)
	}

	for j := 0; j < old_rows - 1; j += 1 {
		abAppend(&ab, "\r\x1b[0K\x1b[1A")
	}

	// Clean the top line
	abAppend(&ab, "\r\x1b[0K")

	// Write the prompt and the current buffer content
	abAppend(&ab, l.prompt)
	if maskmode {
		// This is tricky for multiline maskmode with variable width...
		// But maskmode usually implies * which is width 1.
		// So we can just print * for each rune?
		// Or just print * for bwidth?
		// Let's print * for each rune.
		buf_slice := l.buf_ptr[:l.len]
		offset := 0
		for offset < l.len {
			abAppend(&ab, "*")
			// advance offset
			b := buf_slice[offset]
			rune_len := 1
			if b & 0xE0 ==
			   0xC0 {rune_len = 2} else if b & 0xF0 == 0xE0 {rune_len = 3} else if b & 0xF8 == 0xF0 {rune_len = 4}
			offset += rune_len
		}
	} else {
		buf_slice := l.buf_ptr[:l.len]
		abAppendBytes(&ab, buf_slice)
	}

	// Show hints
	refreshShowHints(&ab, l, pwidth)

	// If we are at the very end of the screen with our prompt, we need to
	// emit a newline and move the prompt to the first column.
	if cwidth > 0 && cwidth == bwidth && (cwidth + pwidth) % l.cols == 0 {
		abAppend(&ab, "\n\r")
		rows += 1
		if rows > l.oldrows {
			l.oldrows = rows
		}
	}

	// Move cursor to right position
	rpos2 := (pwidth + cwidth + l.cols) / l.cols

	if rows - rpos2 > 0 {
		seq := fmt.tprintf("\x1b[%dA", rows - rpos2)
		abAppend(&ab, seq)
	}

	col := (pwidth + cwidth) % l.cols
	if col > 0 {
		seq := fmt.tprintf("\r\x1b[%dC", col)
		abAppend(&ab, seq)
	} else {
		abAppend(&ab, "\r")
	}

	l.oldpos = cwidth // Store visual position for next time

	posix.write(posix.FD(l.ofd), raw_data(ab.b), c.size_t(len(ab.b)))
}

refreshLine :: proc(l: ^State) {
	if mlmode {
		refreshMultiLine(l)
	} else {
		refreshSingleLine(l)
	}
}

refreshLineWithCompletion :: proc(l: ^State, lc: ^Completions) {
	// Obtain the table of completions if the caller didn't provide one.
	ctable: Completions
	lc_ptr := lc
	if lc_ptr == nil {
		buf_str := string(l.buf_ptr[:l.len])
		completion_callback(buf_str, &ctable)
		lc_ptr = &ctable
	}

	// Show the edited line with completion if possible, or just refresh.
	if l.completion_idx < lc_ptr.len {
		saved_len := l.len
		saved_pos := l.pos
		saved_buf_ptr := l.buf_ptr

		l.len = len(lc_ptr.cvec[l.completion_idx])
		l.pos = l.len
		l.buf_ptr = raw_data(transmute([]byte)lc_ptr.cvec[l.completion_idx])

		refreshLine(l)

		l.len = saved_len
		l.pos = saved_pos
		l.buf_ptr = saved_buf_ptr
	} else {
		refreshLine(l)
	}

	// Free the completions table if needed.
	if lc_ptr == &ctable {
		freeCompletions(&ctable)
	}
}

completeLine :: proc(l: ^State, keypressed: rune) -> rune {
	lc: Completions
	c := keypressed

	buf_str := string(l.buf_ptr[:l.len])
	completion_callback(buf_str, &lc)

	if lc.len == 0 {
		linenoiseBeep()
		l.in_completion = false
	} else {
		switch c {
		case TAB:
			if !l.in_completion {
				l.in_completion = true
				l.completion_idx = 0
			} else {
				l.completion_idx = (l.completion_idx + 1) % (lc.len + 1)
				if l.completion_idx == lc.len {
					linenoiseBeep()
				}
			}
			c = 0
		case ESC:
			// Re-show original buffer
			if l.completion_idx < lc.len {
				refreshLine(l)
			}
			l.in_completion = false
			c = 0
		case:
			// Update buffer and return
			if l.completion_idx < lc.len {
				completion := lc.cvec[l.completion_idx]
				nwritten := len(completion)
				// Ensure buffer is large enough
				if nwritten < l.buflen {
					copy(l.buf_ptr[:nwritten], completion)
					l.len = nwritten
					l.pos = nwritten
					l.buf_ptr[l.len] = 0
				}
			}
			l.in_completion = false
		}

		// Show completion or original buffer
		if l.in_completion && l.completion_idx < lc.len {
			refreshLineWithCompletion(l, &lc)
		} else {
			refreshLine(l)
		}
	}

	freeCompletions(&lc)
	return c
}

linenoiseEditInsert :: proc(l: ^State, r: rune) -> int {
	// Encode rune to bytes
	b, n := utf8.encode_rune(r)
	slice := b[:n]

	if l.len + n <= l.buflen {
		if l.len == l.pos {
			// Append
			copy(l.buf_ptr[l.pos:l.buflen], slice)
			l.pos += n
			l.len += n
			l.buf_ptr[l.len] = 0

			// Optimization for appending at end
			if !mlmode &&
			   l.plen + getByteSliceWidth(l.buf_ptr[:l.len]) < l.cols &&
			   hints_callback == nil {
				if maskmode {
					posix.write(posix.FD(l.ofd), raw_data(str_bytes("*")), 1)
				} else {
					posix.write(posix.FD(l.ofd), raw_data(slice), c.size_t(n))
				}
			} else {
				refreshLine(l)
			}
		} else {
			// Insert in middle
			// memmove
			for i := l.len; i >= l.pos; i -= 1 {
				l.buf_ptr[i + n] = l.buf_ptr[i]
			}
			copy(l.buf_ptr[l.pos:l.buflen], slice)
			l.len += n
			l.pos += n
			l.buf_ptr[l.len] = 0
			refreshLine(l)
		}
	}
	return 0
}

linenoiseEditMoveLeft :: proc(l: ^State) {
	if l.pos > 0 {
		prev_pos := l.pos - 1
		for prev_pos > 0 && (l.buf_ptr[prev_pos] & 0xC0) == 0x80 {
			prev_pos -= 1
		}
		l.pos = prev_pos
		refreshLine(l)
	}
}

linenoiseEditMoveRight :: proc(l: ^State) {
	if l.pos != l.len {
		next_pos := l.pos + 1
		for next_pos < l.len && (l.buf_ptr[next_pos] & 0xC0) == 0x80 {
			next_pos += 1
		}
		l.pos = next_pos
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
		next_pos := l.pos + 1
		for next_pos < l.len && (l.buf_ptr[next_pos] & 0xC0) == 0x80 {
			next_pos += 1
		}
		diff := next_pos - l.pos

		// memmove
		for i := l.pos; i <= l.len - diff; i += 1 {
			l.buf_ptr[i] = l.buf_ptr[i + diff]
		}
		l.len -= diff
		refreshLine(l)
	}
}

linenoiseEditBackspace :: proc(l: ^State) {
	if l.pos > 0 && l.len > 0 {
		prev_pos := l.pos - 1
		for prev_pos > 0 && (l.buf_ptr[prev_pos] & 0xC0) == 0x80 {
			prev_pos -= 1
		}
		diff := l.pos - prev_pos

		// memmove
		for i := 0; i <= l.len - l.pos; i += 1 {
			l.buf_ptr[prev_pos + i] = l.buf_ptr[l.pos + i]
		}
		l.pos -= diff
		l.len -= diff
		refreshLine(l)
	}
}

linenoiseEditDeletePrevWord :: proc(l: ^State) {
	old_pos := l.pos

	for l.pos > 0 {
		prev_pos := l.pos - 1
		for prev_pos > 0 && (l.buf_ptr[prev_pos] & 0xC0) == 0x80 {
			prev_pos -= 1
		}
		if l.buf_ptr[prev_pos] == ' ' {
			l.pos = prev_pos
		} else {
			break
		}
	}

	for l.pos > 0 {
		prev_pos := l.pos - 1
		for prev_pos > 0 && (l.buf_ptr[prev_pos] & 0xC0) == 0x80 {
			prev_pos -= 1
		}
		if l.buf_ptr[prev_pos] != ' ' {
			l.pos = prev_pos
		} else {
			break
		}
	}

	diff := old_pos - l.pos
	// memmove
	count := l.len - old_pos + 1
	for i := 0; i < count; i += 1 {
		l.buf_ptr[l.pos + i] = l.buf_ptr[old_pos + i]
	}
	l.len -= diff
	refreshLine(l)
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

linenoiseNoTTY :: proc() -> string {
	buf: [dynamic]byte
	for {
		b: byte
		n := posix.read(posix.STDIN_FILENO, &b, 1)
		if n <= 0 { 	// EOF or Error
			if len(buf) == 0 {
				delete(buf)
				return ""
			} else {
				break
			}
		}
		if b == '\n' {
			break
		}
		append(&buf, b)
	}
	return string(buf[:])
}

linenoiseEditFeed :: proc(l: ^State) -> string {
	if !posix.isatty(posix.FD(l.ifd)) {
		return linenoiseNoTTY()
	}

	b: byte
	nread := posix.read(posix.FD(l.ifd), &b, 1)
	if nread <= 0 {
		return ""
	}

	// Read UTF-8 sequence
	r: rune
	if b < 0x80 {
		r = rune(b)
	} else {
		len_needed := 0
		if b & 0xE0 ==
		   0xC0 {len_needed = 1} else if b & 0xF0 == 0xE0 {len_needed = 2} else if b & 0xF8 == 0xF0 {len_needed = 3}

		if len_needed > 0 {
			seq: [4]byte
			seq[0] = b
			n := posix.read(posix.FD(l.ifd), &seq[1], c.size_t(len_needed))
			if n == int(len_needed) {
				r_val, _ := utf8.decode_rune(seq[:1 + len_needed])
				r = r_val
			} else {
				r = rune(b)
			}
		} else {
			r = rune(b)
		}
	}

	// Completion handling
	if (l.in_completion || b == TAB) && completion_callback != nil {
		r = completeLine(l, r)
		if r == 0 {
			return "more"
		}
		if r < 0x80 {
			b = byte(r)
		} else {
			b = 0 // Force default
		}
	}

	switch b {
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
		linenoiseClearScreen()
		refreshLine(l)
	case CTRL_W:
		linenoiseEditDeletePrevWord(l)
	case:
		linenoiseEditInsert(l, r)
	}

	return "more" // Special value to indicate more editing needed
}

linenoise :: proc(prompt: string) -> string {
	if !posix.isatty(posix.STDIN_FILENO) {
		return linenoiseNoTTY()
	}

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

linenoisePrintKeyCodes :: proc() {
	quit: [4]byte = {' ', ' ', ' ', ' '}

	fmt.println("Linenoise key codes debugging mode.")
	fmt.println("Press keys to see scan codes. Type 'quit' at any time to exit.")

	if enableRawMode(c.int(posix.STDIN_FILENO)) != .None {
		return
	}
	defer disableRawMode(c.int(posix.STDIN_FILENO))

	for {
		c_in: byte
		nread := posix.read(posix.STDIN_FILENO, &c_in, 1)
		if nread <= 0 {
			continue
		}

		// Shift quit buffer
		copy(quit[:3], quit[1:])
		quit[3] = c_in

		if string(quit[:]) == "quit" {
			break
		}

		is_print := c_in >= 32 && c_in <= 126
		display_char := is_print ? rune(c_in) : '?'

		fmt.printf("'%c' %02x (%d) (type quit to exit)\n\r", display_char, c_in, c_in)
	}
}
