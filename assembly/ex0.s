.data
_hello:
  .asciz "Hello, world!\n"

.text
.globl _main
_main:
  subq $8, %rsp

  movq $0, %rax
  leaq _hello(%rip), %rdi
  call _printf

  movq $0, %rdi
  call _exit
