package main

import "core:fmt"
import "core:os"

import ln "../"
import "core:strings"

example_hints_callback :: proc(buf: string, color: ^int, bold: ^int) -> string {
	if strings.compare(buf, "hello") == 0 {
		color^ = 35
		bold^ = 0
		return " World"
	}
	return ""
}

completion :: proc(buf: string, lc: ^ln.Completions) {
	if len(buf) > 0 && buf[0] == 'h' {
		ln.linenoiseAddCompletion(lc, "hello")
		ln.linenoiseAddCompletion(lc, "hello there")
	}
}

main :: proc() {
	fmt.println("Linenoise Odin Test")

	ln.linenoiseSetCompletionCallback(completion)
	ln.linenoiseSetHintsCallback(example_hints_callback)

	if len(os.args) > 1 && os.args[1] == "--keycodes" {
		ln.linenoisePrintKeyCodes()
		return
	}

	if len(os.args) > 1 && os.args[1] == "--beep" {
		ln.linenoiseBeep()
		return
	}

	if len(os.args) > 1 && os.args[1] == "--mask" {
		ln.linenoiseMaskModeEnable()
	}

	if len(os.args) > 1 && os.args[1] == "--multiline" {
		ln.linenoiseSetMultiLine(true)
		fmt.println("Multi-line mode enabled")
	}

	history_file := "history.txt"
	ln.linenoiseHistoryLoad(history_file)

	buf: [ln.LINENOISE_MAX_LINE]byte
	for {
		n, err := ln.linenoise("hello> ", buf[:])
		if n == 0 || err != .None {
			break
		}

		line := string(buf[:n])
		fmt.printf("echo: '%s'\n", line)

		// Add to history
		ln.linenoiseHistoryAdd(line)
		ln.linenoiseHistorySave(history_file)

		if line == "exit" || line == "quit" {
			break
		}
	}
}
