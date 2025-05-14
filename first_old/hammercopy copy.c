#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <x86intrin.h>
#include <unistd.h>

// Hammering function: flushes and accesses two memory addresses repeatedly
void hammer(void *addr1, void *addr2, size_t reps) {
    volatile uint64_t *p1 = (uint64_t *)addr1;
    volatile uint64_t *p2 = (uint64_t *)addr2;
    for (size_t i = 0; i < reps; i++) {
        _mm_clflush((const void *)p1);  // Explicit cast to avoid warning
        _mm_clflush((const void *)p2);
        *p1;  // Access to keep memory active
        *p2;
    }
}

int main() {
    size_t reps = 10000000;           // Number of hammering iterations
    size_t size = 2 * 4096;           // Allocate two pages
    void *mem = aligned_alloc(4096, size);  // Allocate page-aligned memory
    if (!mem) {
        perror("alloc");
        return 1;
    }

    // Run the hammering between two adjacent pages
    hammer(mem, (char *)mem + 4096, reps);

    free(mem);  // Clean up
    return 0;
}
