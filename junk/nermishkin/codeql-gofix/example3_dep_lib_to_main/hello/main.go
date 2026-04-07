package main

import (
	"os/exec"

	"a.yandex-team.ru/junk/nermishkin/codeql-gofix/example3_dep_lib_to_main/internal/source"
)

func main() {
	command := source.ReadCommand()
	if command == "" {
		return
	}

	_ = exec.Command(command).Run()
}
