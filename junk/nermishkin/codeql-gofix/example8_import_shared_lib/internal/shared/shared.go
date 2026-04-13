package shared

import "os"

func ReadCommand(defaultCommand string) string {
	if len(os.Args) > 1 {
		return os.Args[1]
	}

	return defaultCommand
}
