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
rest1824683:
    movq -8(%rbp), %rax
    movq $0, 8(%rax)
    movq -96(%rbp), %rax
    movq 8(%rax), %r11
    movq %r11, -104(%rbp)
    movq -104(%rbp), %rax
    jmp conclusion
header1824684:
    movq -48(%rbp), %rax
    movq 8(%rax), %r11
    movq %r11, -144(%rbp)
    movq -32(%rbp), %rax
    movq 8(%rax), %r11
    movq %r11, -136(%rbp)
    movq -144(%rbp), %rax
    cmpq -136(%rbp), %rax
    setl %al
    movzbq %al, %rax
    movq %rax, -56(%rbp)
    movq -56(%rbp), %rax
    cmpq $0, %rax
    je rest1824683
    jmp body1824685
body1824685:
    movq $1, %rdi
    call _make_vector
    movq %rax, -128(%rbp)
    movq -128(%rbp), %r11
    movq %r11, -8(%rbp)
    movq -48(%rbp), %rax
    movq 8(%rax), %r11
    movq %r11, -120(%rbp)
    movq -120(%rbp), %rax
    addq $1, %rax
    movq %rax, -112(%rbp)
    movq -48(%rbp), %rax
    movq -112(%rbp), %r11
    movq %r11, 8(%rax)
    jmp header1824684
_main:
    pushq %rbp
    movq %rsp, %rbp
    addq $-144, %rsp
    movq $1, %rdi
    call _make_vector
    movq %rax, -40(%rbp)
    movq -40(%rbp), %r11
    movq %r11, -32(%rbp)
    call _read_int64
    movq %rax, -24(%rbp)
    movq -32(%rbp), %rax
    movq -24(%rbp), %r11
    movq %r11, 8(%rax)
    movq $1, %rdi
    call _make_vector
    movq %rax, -16(%rbp)
    movq -16(%rbp), %r11
    movq %r11, -48(%rbp)
    movq -48(%rbp), %rax
    movq $0, 8(%rax)
    movq $1, %rdi
    call _make_vector
    movq %rax, -88(%rbp)
    movq -88(%rbp), %r11
    movq %r11, -64(%rbp)
    movq -64(%rbp), %rax
    movq $5, 8(%rax)
    movq $1, %rdi
    call _make_vector
    movq %rax, -80(%rbp)
    movq -80(%rbp), %r11
    movq %r11, -96(%rbp)
    movq -96(%rbp), %rax
    movq $15, 8(%rax)
    movq $1, %rdi
    call _make_vector
    movq %rax, -72(%rbp)
    movq -72(%rbp), %r11
    movq %r11, -8(%rbp)
    jmp header1824684
