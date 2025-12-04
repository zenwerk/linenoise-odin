package main

import "core:fmt"
import "core:os"

import "core:strings"

example_hints_callback :: proc(buf: string, color: ^int, bold: ^int) -> string {
	if strings.compare(buf, "hello") == 0 {
		color^ = 35
		bold^ = 0
		return " World"
	}
	return ""
}

completion :: proc(buf: string, lc: ^Completions) {
	if len(buf) > 0 && buf[0] == 'h' {
		linenoiseAddCompletion(lc, "hello")
		linenoiseAddCompletion(lc, "hello there")
	}
}

main :: proc() {
	fmt.println("Linenoise Odin Test")

	linenoiseSetCompletionCallback(completion)
	linenoiseSetHintsCallback(example_hints_callback)

	if len(os.args) > 1 && os.args[1] == "--keycodes" {
		linenoisePrintKeyCodes()
		return
	}

	if len(os.args) > 1 && os.args[1] == "--beep" {
		linenoiseBeep()
		return
	}

	if len(os.args) > 1 && os.args[1] == "--mask" {
		linenoiseMaskModeEnable()
	}

	if len(os.args) > 1 && os.args[1] == "--multiline" {
		linenoiseSetMultiLine(true)
		fmt.println("Multi-line mode enabled")
	}

	history_file := "history.txt"
	linenoiseHistoryLoad(history_file)

	for {
		line := linenoise("hello> ")
		if line == "" {
			break
		}

		fmt.printf("echo: '%s'\n", line)

		// Add to history (TODO)
		linenoiseHistoryAdd(line)
		linenoiseHistorySave(history_file)

		if line == "exit" || line == "quit" {
			break
		}

		delete(line) // linenoise returns allocated string
	}
}
