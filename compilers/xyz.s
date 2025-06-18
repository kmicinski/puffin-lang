/* clang -arch x86_64 -o xyz xyz.s   (or: cc …)                       */
/* AT&T syntax, Mach‑O layout, everything on the stack               */

        .data
fmt_in:  .asciz  "%ld"
fmt_out: .asciz  "%ld\n"

        .text
        .globl  _main
_main:
        pushq   %rbp
        movq    %rsp, %rbp
        pushq   %rbx              # callee‑saved
        subq    $24,  %rsp        # locals: x, y, z  (3×8 bytes)

        # x ← read
        leaq    fmt_in(%rip), %rdi
        leaq    -8(%rbp),  %rsi
        xorl    %eax,   %eax      # varargs ABI
        callq   _scanf

        # y = 2*x + 3
        movq    -8(%rbp), %rax
        leaq    3(,%rax,2), %rbx
        movq    %rbx, -16(%rbp)

        # z = x + y*y
        imulq   %rbx, %rbx        # y*y
        addq    -8(%rbp), %rbx
        movq    %rbx, -24(%rbp)

        # result = z + 1
        incq    %rbx

        # print result
        leaq    fmt_out(%rip), %rdi
        movq    %rbx, %rsi
        xorl    %eax,  %eax
        callq   _printf

        # epilogue
        addq    $24,  %rsp
        popq    %rbx
        popq    %rbp
        retq                      # `ret` works too
