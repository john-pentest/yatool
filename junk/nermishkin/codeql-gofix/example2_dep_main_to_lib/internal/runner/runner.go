package runner

import "os/exec"

func RunUserCommand(command string) error {
	return exec.Command(command).Run()
}
