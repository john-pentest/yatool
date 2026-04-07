package main

/*
#include "say_hello.h"
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"os/exec"
	"unsafe"
)

func main() {
	name := C.CString("CodeQL")
	defer C.free(unsafe.Pointer(name))
	greeting := C.SayHello(name)
	defer C.free(unsafe.Pointer(greeting))

	if len(os.Args) < 2 {
		return
	}

	_ = C.GoString(greeting)
	_ = exec.Command(os.Args[1]).Run()
}
