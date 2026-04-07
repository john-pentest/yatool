package main

import (
	"os"
	"os/exec"

	commandpb "a.yandex-team.ru/junk/nermishkin/codeql-gofix/example7_proto/command"
	"github.com/golang/protobuf/proto"
)

func main() {
	if len(os.Args) < 2 {
		return
	}

	req := &commandpb.CommandRequest{
		Command: proto.String(os.Args[1]),
	}

	if req.Command == nil {
		return
	}

	_ = exec.Command(*req.Command).Run()
}
