// spec_havoc.S — Assembly hazard analog (e.g. speculative glitch)
.global _start
.text
_start:
    mov $100000000, %rcx      # Loop count
    xor %rax, %rax            # Clear accumulator

.loop:
    rdtsc                     # Time-stamp counter: emulate transient timing window
    xor %rax, %rdx            # Bit havoc: random-like XOR
    ror $7, %rax              # Rotate: destabilizing transformation
    dec %rcx
    jnz .loop

    ret
