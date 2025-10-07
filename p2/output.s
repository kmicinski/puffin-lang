.globl _main
.extern _read_int64
.extern _print_int64
_main:
    pushq %rbp
    movq %rsp, %rbp
    addq $0, %rsp
    movq $42, %rax
    movq %rax, %rdi
    call _print_int64
    movq $0, %rax
    movq %rbp, %rsp
    popq %rbp
    ret

