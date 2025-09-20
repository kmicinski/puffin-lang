.globl main
.extern read_int64
.extern print_int64
main:
    pushq %rbp
    movq %rsp, %rbp
    addq $-32, %rsp
    call read_int64
    movq %rax, -24(%rbp)
    call read_int64
    movq %rax, -16(%rbp)
    movq -16(%rbp), %rax
    negq %rax
    movq %rax, -8(%rbp)
    movq -24(%rbp), %rax
    addq -8(%rbp), %rax
    movq %rax, -32(%rbp)
    movq -32(%rbp), %rax
    movq %rax, %rdi
    call print_int64
    movq $0, %rax
    movq %rbp, %rsp
    popq %rbp
    ret
.section .note.GNU-stack,"",@progbits

