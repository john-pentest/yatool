package main

import (
    "os"
    "os/exec"

    "github.com/golang/protobuf/proto"
)

func main() {
    if len(os.Args) < 2 {
        return
    }

    command := *proto.String(os.Args[1])
    _ = exec.Command(command).Run()
}
