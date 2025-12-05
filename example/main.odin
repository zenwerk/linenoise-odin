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

	for {
		line, _ := ln.linenoise("hello> ")
		if line == "" {
			break
		}

		fmt.printf("echo: '%s'\n", line)

		// Add to history (TODO)
		ln.linenoiseHistoryAdd(line)
		ln.linenoiseHistorySave(history_file)

		if line == "exit" || line == "quit" {
			break
		}

		delete(line) // linenoise returns allocated string
	}
}
