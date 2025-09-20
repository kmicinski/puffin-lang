.globl main
.extern read_int64
.extern print_int64
main:
    pushq %rbp
    movq %rsp, %rbp
    addq $-32, %rsp
    movq $2, -16(%rbp)
    movq -16(%rbp), %rax
    movq %rax, -8(%rbp)
    movq -8(%rbp), %rax
    movq %rax, -24(%rbp)
    movq -24(%rbp), %rax
    movq %rax, %rdi
    call print_int64
    movq $0, %rax
    movq %rbp, %rsp
    popq %rbp
    ret
.section .note.GNU-stack,"",@progbits

