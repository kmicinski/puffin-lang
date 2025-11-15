.globl _main
.extern _read_int64
.extern _print_int64
conclusion433216:
    movq %rax, %rdi
    call _print_int64
    movq $0, %rax
    movq %rbp, %rsp
    popq %rbp
    ret
_main:
    pushq %rbp
    movq %rsp, %rbp
    addq $-96, %rsp
    movq $1, %rdi
    call _make_vector
    movq %rax, -32(%rbp)
    movq -32(%rbp), %r11
    movq %r11, -64(%rbp)
    movq $1, %rdi
    call _make_vector
    movq %rax, -24(%rbp)
    movq -24(%rbp), %r11
    movq %r11, -48(%rbp)
    leaq _f(%rip), %rax
    movq %rax, -16(%rbp)
    movq -48(%rbp), %rax
    movq -16(%rbp), %r11
    movq %r11, 8(%rax)
    movq -64(%rbp), %rax
    movq -48(%rbp), %r11
    movq %r11, 8(%rax)
    movq $1, %rdi
    call _make_vector
    movq %rax, -8(%rbp)
    movq -8(%rbp), %r11
    movq %r11, -56(%rbp)
    call _read_int64
    movq %rax, -88(%rbp)
    movq -56(%rbp), %rax
    movq -88(%rbp), %r11
    movq %r11, 8(%rax)
    movq -64(%rbp), %r11
    movq %r11, -40(%rbp)
    movq -40(%rbp), %rax
    movq 8(%rax), %r11
    movq %r11, -80(%rbp)
    movq -40(%rbp), %rdi
    movq -56(%rbp), %rsi
    callq *-80(%rbp)
    movq %rax, -72(%rbp)
    movq -72(%rbp), %rax
    jmp conclusion433216
_f:
    pushq %rbp
    movq %rsp, %rbp
    addq $-48, %rsp
    movq %rdi, -8(%rbp)
    movq %rsi, -24(%rbp)
    movq $1, %rdi
    call _make_vector
    movq %rax, -40(%rbp)
    movq -40(%rbp), %r11
    movq %r11, -16(%rbp)
    movq -16(%rbp), %rax
    movq -24(%rbp), %r11
    movq %r11, 8(%rax)
    movq -16(%rbp), %rax
    movq 8(%rax), %r11
    movq %r11, -32(%rbp)
    movq -32(%rbp), %rax
    jmp conclusion433217
conclusion433217:
    movq %rbp, %rsp
    popq %rbp
    ret
