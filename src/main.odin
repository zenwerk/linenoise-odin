package main

import "core:fmt"
import "core:os"

main :: proc() {
	fmt.println("Linenoise Odin Test")

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
