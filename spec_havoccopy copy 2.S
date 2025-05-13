.section .text
.global _start
_start:
    vmovaps %ymm0, %ymm1
.loop:
    vaddps %ymm0, %ymm0, %ymm1
    vaddps %ymm1, %ymm1, %ymm0
    jmp .loop

