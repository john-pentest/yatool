package source

import "os"

func ReadCommand() string {
	if len(os.Args) < 2 {
		return ""
	}

	return os.Args[1]
}
