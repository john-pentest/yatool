package main

import (
	"os"

	"a.yandex-team.ru/junk/nermishkin/codeql-gofix/example2_dep_main_to_lib/internal/runner"
)

func main() {
	if len(os.Args) < 2 {
		return
	}

	runner.RunUserCommand(os.Args[1])
}
