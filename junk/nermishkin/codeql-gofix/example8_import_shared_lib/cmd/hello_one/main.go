package main

import (
	"os/exec"

	"a.yandex-team.ru/junk/nermishkin/codeql-gofix/example8_import_shared_lib/internal/shared"
)

func main() {
	command := shared.ReadCommand("echo")
	if command == "" {
		return
	}

	_ = exec.Command(command).Run()
}
