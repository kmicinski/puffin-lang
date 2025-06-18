.globl _main
.extern _read_int64
_main:
    pushq %rbp
    movq %rsp, %rbp
    subq $48, %rsp
    call _read_int64
    movq %rax, -36(%rbp)
    movq -4(%rbp), %rax
    movq %rax, -36(%rbp)
    call _read_int64
    movq %rax, -32(%rbp)
    movq -40(%rbp), %rax
    movq %rax, -32(%rbp)
    movq -40(%rbp), %rax
    addq -40(%rbp), %rax
    movq %rax, -28(%rbp)
    movq -40(%rbp), %rax
    addq -28(%rbp), %rax
    movq %rax, -16(%rbp)
    movq -12(%rbp), %rax
    movq %rax, -16(%rbp)
    movq -4(%rbp), %rax
    addq -12(%rbp), %rax
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rax
    negq %rax
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    addq -4(%rbp), %rax
    movq %rax, -20(%rbp)
    movq -20(%rbp), %rax
    leave
    ret

