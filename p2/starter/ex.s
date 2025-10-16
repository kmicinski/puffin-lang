.globl _main
.extern _read_int64
.extern _print_int64
conclusion:
    movq %rax, %rdi
    call _print_int64
    movq $0, %rax
    movq %rbp, %rsp
    popq %rbp
    ret
lab239896:
    movq $2, %rax
    cmpq -16(%rbp), %rax
    setl %al
    movzbq %al, %rax
    movq %rax, -80(%rbp)
    movq $0, %rax
    cmpq -80(%rbp), %rax
    je lab239898
    jmp lab239899
lab239897:
    movq $3, %rax
    jmp conclusion
lab239898:
    movq $3, -48(%rbp)
    cmpq $1, -48(%rbp)
    setl %al
    movzbq %al, %rax
    movq %rax, -72(%rbp)
    movq -72(%rbp), %rax
    jmp conclusion
lab239899:
    movq $2, %rax
    negq %rax
    movq %rax, -8(%rbp)
    movq $1, %rax
    addq -8(%rbp), %rax
    movq %rax, -64(%rbp)
    movq -64(%rbp), %rax
    movq %rax, -48(%rbp)
    cmpq $1, -48(%rbp)
    setl %al
    movzbq %al, %rax
    movq %rax, -56(%rbp)
    movq -56(%rbp), %rax
    jmp conclusion
_main:
    pushq %rbp
    movq %rsp, %rbp
    addq $-80, %rsp
    call _read_int64
    movq %rax, -40(%rbp)
    movq $1, %rax
    addq -40(%rbp), %rax
    movq %rax, -32(%rbp)
    movq -32(%rbp), %rax
    movq %rax, -16(%rbp)
    movq $0, %rax
    cmpq -16(%rbp), %rax
    setl %al
    movzbq %al, %rax
    movq %rax, -24(%rbp)
    movq $0, %rax
    cmpq -24(%rbp), %rax
    je lab239896
    jmp lab239897
