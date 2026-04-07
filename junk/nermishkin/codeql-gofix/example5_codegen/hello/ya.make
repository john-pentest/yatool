GO_PROGRAM()

PEERDIR(
    ${GOSTD}/os
    ${GOSTD}/os/exec
)

RUN_PYTHON3(gen_main.py STDOUT main.go)

END()
