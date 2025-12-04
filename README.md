# linenoise-odin

Odin port of [linenoise](https://github.com/antirez/linenoise) using Google AntiGravity.

## How to use

```odin
package main

import "core:fmt"
import ln "linenoise"

main :: proc() {
    // Load history
    history_file := "history.txt"
    ln.linenoiseHistoryLoad(history_file)

    for {
        // Get input
        line := ln.linenoise("hello> ")
        if line == "" {
            break
        }

        fmt.printf("echo: '%s'\n", line)

        // Add to history and save
        ln.linenoiseHistoryAdd(line)
        ln.linenoiseHistorySave(history_file)

        if line == "exit" {
            break
        }
        
        // Free memory
        delete(line)
    }
}
```

## Features

- **History**: `linenoiseHistoryAdd`, `linenoiseHistorySave`, `linenoiseHistoryLoad`
- **Completion**: `linenoiseSetCompletionCallback`
- **Hints**: `linenoiseSetHintsCallback`
- **Multi-line mode**: `linenoiseSetMultiLine(true)`
- **Mask mode**: `linenoiseMaskModeEnable()` (password input)

## License

BSD-2-Clause license