package main

import (
	"os"
	"os/exec"
)

func main() {
	if len(os.Args) < 2 {
		return
	}

	command := os.Args[1]
	_ = exec.Command(command).Run()
}
