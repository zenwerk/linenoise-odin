package main

import "core:fmt"
import "core:os"

main :: proc() {
	fmt.println("Linenoise Odin Test")

	if len(os.args) > 1 && os.args[1] == "--keycodes" {
		linenoisePrintKeyCodes()
		return
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
