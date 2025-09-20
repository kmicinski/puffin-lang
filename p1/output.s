.globl _main
.extern _read_int64
.extern _print_int64
_main:
    pushq %rbp
    movq %rsp, %rbp
    addq $-48, %rsp
    movq $5, %rax
    addq $3, %rax
    movq %rax, -32(%rbp)
    call _read_int64
    movq %rax, -24(%rbp)
    movq $2, %rax
    addq -24(%rbp), %rax
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    negq %rax
    movq %rax, -8(%rbp)
    movq -32(%rbp), %rax
    addq -8(%rbp), %rax
    movq %rax, -40(%rbp)
    movq -40(%rbp), %rax
    movq %rax, %rdi
    call _print_int64
    movq $0, %rax
    movq %rbp, %rsp
    popq %rbp
    ret

