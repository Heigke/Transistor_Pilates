#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <x86intrin.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>

#define DEFAULT_HAMMER_COUNT 10000000
#define PAGE_SIZE 4096
#define NUM_THREADS 4
#define PATTERN_SIZE 64
#define CONSECUTIVE_RUNS 3  // Number of runs to verify consistency

// Configurable parameters
typedef struct {
    void *addr1;
    void *addr2;
    size_t iterations;
    int thread_id;
    uint64_t *flip_count;
    uint64_t *flip_positions;  // Array to store positions of bit flips
    size_t *num_flip_positions; // Number of positions stored
    bool verify;
    uint64_t *victim_area;
    size_t victim_size;
    uint8_t expected_pattern;
} hammer_args_t;

// Pattern for victim memory to make bit flips more detectable
const uint8_t PATTERNS[][PATTERN_SIZE] = {
    {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF},  // All 1s
    {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},  // All 0s
    {0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA},  // Alternating 10
    {0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55}   // Alternating 01
};

// Timestamp for measuring performance
uint64_t get_timestamp_ms() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (ts.tv_sec * 1000) + (ts.tv_nsec / 1000000);
}

// Memory fence to ensure operations complete
inline void memory_fence() {
    asm volatile("mfence" ::: "memory");
}

// Aggressive hammering function using assembly for even faster access
void hammer_aggressive(void *addr1, void *addr2, size_t reps) {
    volatile uint64_t *p1 = (uint64_t *)addr1;
    volatile uint64_t *p2 = (uint64_t *)addr2;
    
    for (size_t i = 0; i < reps; i++) {
        // Flush cache lines
        _mm_clflush((const void *)p1);
        _mm_clflush((const void *)p2);
        memory_fence();
        
        // Force memory access and ensure it's not optimized away
        asm volatile(
            "mov (%0), %%rax\n"
            "mov (%1), %%rbx\n"
            :
            : "r" (p1), "r" (p2)
            : "rax", "rbx", "memory"
        );
        memory_fence();
    }
}

// Verify function to check for bit flips in victim area
uint64_t verify_memory(uint8_t *start, size_t size, uint8_t expected_pattern, 
                     uint64_t *flip_positions, size_t *num_positions, size_t max_positions) {
    uint64_t flips = 0;
    *num_positions = 0;
    
    for (size_t i = 0; i < size; i++) {
        uint8_t val = start[i];
        
        if (val != expected_pattern) {
            flips++;
            
            // Store position for later verification
            if (*num_positions < max_positions) {
                flip_positions[(*num_positions)++] = i;
            }
            
            // Print detailed information about the bit flip
            printf("BIT FLIP DETECTED at address %p: expected 0x%02x, got 0x%02x\n", 
                   start + i, expected_pattern, val);
            
            // Show which bits flipped
            uint8_t flipped_bits = val ^ expected_pattern;
            printf("Flipped bits: ");
            for (int bit = 7; bit >= 0; bit--) {
                if ((flipped_bits >> bit) & 1) {
                    printf("%d ", bit);
                }
            }
            printf("\n");
        }
    }
    return flips;
}

// Thread function for hammering
void *hammer_thread(void *arg) {
    hammer_args_t *hargs = (hammer_args_t *)arg;
    
    printf("Thread %d starting to hammer between %p and %p for %zu iterations\n", 
           hargs->thread_id, hargs->addr1, hargs->addr2, hargs->iterations);
    
    uint64_t start_time = get_timestamp_ms();
    hammer_aggressive(hargs->addr1, hargs->addr2, hargs->iterations);
    uint64_t end_time = get_timestamp_ms();
    
    printf("Thread %d completed hammering in %lu ms\n", 
           hargs->thread_id, (end_time - start_time));
    
    // Verify memory if requested
    if (hargs->verify && hargs->victim_area != NULL) {
        uint64_t flips = verify_memory((uint8_t *)hargs->victim_area, 
                                      hargs->victim_size, 
                                      hargs->expected_pattern,
                                      hargs->flip_positions,
                                      hargs->num_flip_positions,
                                      hargs->victim_size);
        *(hargs->flip_count) += flips;
        
        if (flips > 0) {
            printf("Thread %d found %lu bit flips!\n", hargs->thread_id, flips);
        }
    }
    
    return NULL;
}

// Function to attempt to get physically contiguous memory (best effort)
void *allocate_contiguous_memory(size_t size, bool use_hugepages) {
    void *mem = NULL;
    
    if (use_hugepages) {
        // Try with hugepages if available
        mem = mmap(NULL, size, PROT_READ | PROT_WRITE, 
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
        
        if (mem != MAP_FAILED) {
            printf("Successfully allocated memory using hugepages\n");
            return mem;
        }
        
        printf("Hugepages allocation failed, falling back to standard pages\n");
    }
    
    // Try with /dev/mem for physical memory access (requires root)
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd != -1) {
        // Map physical memory - WARNING: Very system dependent and potentially dangerous
        mem = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x10000000);
        close(fd);
        
        if (mem != MAP_FAILED) {
            printf("Successfully mapped physical memory via /dev/mem\n");
            return mem;
        }
        
        printf("Physical memory mapping failed: %s\n", strerror(errno));
    }
    
    // Fall back to regular aligned allocation
    mem = aligned_alloc(PAGE_SIZE, size);
    if (mem) {
        // Touch each page to ensure it's mapped and reduce page faults during test
        for (size_t i = 0; i < size; i += PAGE_SIZE) {
            *((volatile uint8_t *)mem + i) = 0;
        }
        printf("Using standard aligned memory allocation\n");
    }
    
    return mem;
}

// Initialize memory with pattern
void init_memory_pattern(void *mem, size_t size, const uint8_t *pattern, size_t pattern_size) {
    uint8_t *ptr = (uint8_t *)mem;
    for (size_t i = 0; i < size; i++) {
        ptr[i] = pattern[i % pattern_size];
    }
    
    // Ensure memory is actually written to RAM
    for (size_t i = 0; i < size; i += 64) {  // Flush cache line by cache line
        _mm_clflush((const void *)(ptr + i));
    }
    memory_fence();
}

// Verify that bit flips are consistent across runs
bool verify_consistent_flips(uint64_t **flip_positions, size_t *flip_counts, int runs) {
    if (runs <= 1) return true;  // Need at least 2 runs to compare
    
    // Check if we have the same number of flips each time
    for (int i = 1; i < runs; i++) {
        if (flip_counts[i] != flip_counts[0]) {
            printf("CONSISTENCY CHECK: Different number of flips between runs (Run 0: %zu, Run %d: %zu)\n",
                   flip_counts[0], i, flip_counts[i]);
            return false;
        }
    }
    
    // Check each position from first run against other runs
    for (size_t pos = 0; pos < flip_counts[0]; pos++) {
        uint64_t position = flip_positions[0][pos];
        for (int run = 1; run < runs; run++) {
            bool found = false;
            for (size_t j = 0; j < flip_counts[run]; j++) {
                if (flip_positions[run][j] == position) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                printf("CONSISTENCY CHECK: Flip at position %lu not found in run %d\n", 
                       position, run);
                return false;
            }
        }
    }
    
    printf("CONSISTENCY CHECK PASSED: Same bit flips observed across all runs!\n");
    return true;
}

// Perform memory refresh test - write different pattern and see if flips persist
bool perform_refresh_test(void *mem, size_t size, uint64_t *flip_positions, 
                         size_t num_positions, uint8_t original_pattern) {
    printf("\nPerforming memory refresh test...\n");
    
    // First save the current values at flip positions
    uint8_t *memory = (uint8_t *)mem;
    uint8_t *original_values = malloc(num_positions);
    
    if (!original_values) {
        perror("Failed to allocate memory for refresh test");
        return false;
    }
    
    for (size_t i = 0; i < num_positions; i++) {
        original_values[i] = memory[flip_positions[i]];
    }
    
    // Write alternate pattern (invert the original pattern)
    uint8_t refresh_pattern = ~original_pattern;
    init_memory_pattern(mem, size, &refresh_pattern, 1);
    
    // Now write back the original pattern
    init_memory_pattern(mem, size, &original_pattern, 1);
    
    // Check if the flipped bits are still flipped
    int persistent_flips = 0;
    for (size_t i = 0; i < num_positions; i++) {
        if (memory[flip_positions[i]] != original_pattern) {
            persistent_flips++;
        }
    }
    
    free(original_values);
    
    if (persistent_flips == 0) {
        printf("REFRESH TEST: No bit flips persisted after memory refresh.\n");
        printf("This suggests the flips might be due to DRAM refresh issues rather than true Row Hammer.\n");
        return false;
    } else {
        printf("REFRESH TEST: %d/%zu bit flips persisted after memory refresh.\n", 
               persistent_flips, num_positions);
        printf("This strongly suggests true Row Hammer vulnerability.\n");
        return true;
    }
}

int main(int argc, char *argv[]) {
    // Parse command-line arguments
    size_t iterations = DEFAULT_HAMMER_COUNT;
    int num_threads = NUM_THREADS;
    int pattern_index = 0;
    bool verify_mode = true;
    bool use_hugepages = false;
    bool run_consistency_check = false;
    bool run_refresh_test = false;
    
    // Process command line options
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
            iterations = atol(argv[i + 1]);
            i++;
        } else if (strcmp(argv[i], "-t") == 0 && i + 1 < argc) {
            num_threads = atoi(argv[i + 1]);
            i++;
        } else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            pattern_index = atoi(argv[i + 1]) % 4;  // Limit to available patterns
            i++;
        } else if (strcmp(argv[i], "-v") == 0) {
            verify_mode = true;
        } else if (strcmp(argv[i], "-H") == 0) {
            use_hugepages = true;
        } else if (strcmp(argv[i], "-c") == 0) {
            run_consistency_check = true;
        } else if (strcmp(argv[i], "-r") == 0) {
            run_refresh_test = true;
        } else if (strcmp(argv[i], "-h") == 0) {
            printf("Usage: %s [-i iterations] [-t threads] [-p pattern] [-v] [-H] [-c] [-r]\n", argv[0]);
            printf("  -i iterations: Number of hammering iterations (default: %d)\n", DEFAULT_HAMMER_COUNT);
            printf("  -t threads: Number of threads (default: %d)\n", NUM_THREADS);
            printf("  -p pattern: Memory pattern (0=all 1s, 1=all 0s, 2=alternating 10, 3=alternating 01)\n");
            printf("  -v: Enable verification mode (default: on)\n");
            printf("  -H: Attempt to use hugepages for better contiguity\n");
            printf("  -c: Run consistency check (multiple runs to verify same bit flips)\n");
            printf("  -r: Run refresh test to verify persistence of flips\n");
            return 0;
        }
    }
    
    printf("===== Row Hammer Test Configuration =====\n");
    printf("- Hammer iterations: %zu\n", iterations);
    printf("- Threads: %d\n", num_threads);
    printf("- Pattern: %d (0xFF=%02X)\n", pattern_index, PATTERNS[pattern_index][0]);
    printf("- Verification: %s\n", verify_mode ? "enabled" : "disabled");
    printf("- Hugepages: %s\n", use_hugepages ? "enabled" : "disabled");
    printf("- Consistency check: %s\n", run_consistency_check ? "enabled" : "disabled");
    printf("- Refresh test: %s\n", run_refresh_test ? "enabled" : "disabled");
    printf("======================================\n\n");
    
    // Calculate memory requirements
    size_t pages_per_thread = 3;  // Two for hammering, one victim in between
    size_t mem_size = num_threads * pages_per_thread * PAGE_SIZE;
    
    // Result arrays for consistency check
    uint64_t **all_flip_positions = NULL;
    size_t *all_flip_counts = NULL;
    int runs = run_consistency_check ? CONSECUTIVE_RUNS : 1;
    
    if (run_consistency_check) {
        all_flip_positions = malloc(runs * sizeof(uint64_t *));
        all_flip_counts = malloc(runs * sizeof(size_t));
        
        if (!all_flip_positions || !all_flip_counts) {
            perror("Failed to allocate memory for consistency check");
            return 1;
        }
        
        for (int i = 0; i < runs; i++) {
            all_flip_positions[i] = malloc(mem_size * sizeof(uint64_t));
            if (!all_flip_positions[i]) {
                perror("Failed to allocate flip position array");
                return 1;
            }
            all_flip_counts[i] = 0;
        }
    }
    
    // Run the test multiple times for consistency checking
    uint64_t total_flips_all_runs = 0;
    
    for (int run = 0; run < runs; run++) {
        if (run > 0) {
            printf("\n===== Starting Run %d of %d =====\n", run + 1, runs);
        }
        
        // Allocate memory - try to get physically contiguous memory
        void *mem = allocate_contiguous_memory(mem_size, use_hugepages);
        if (!mem) {
            perror("Failed to allocate memory");
            return 1;
        }
        
        printf("Allocated %zu bytes at %p\n", mem_size, mem);
        
        // Initialize memory with selected pattern
        const uint8_t *pattern = PATTERNS[pattern_index];
        init_memory_pattern(mem, mem_size, pattern, PATTERN_SIZE);
        
        // Create threads for hammering
        pthread_t *threads = malloc(num_threads * sizeof(pthread_t));
        hammer_args_t *thread_args = malloc(num_threads * sizeof(hammer_args_t));
        uint64_t *flip_positions = run_consistency_check ? 
                                  all_flip_positions[run] : 
                                  malloc(mem_size * sizeof(uint64_t));
        size_t num_flip_positions = 0;
        uint64_t total_flips = 0;
        
        if (!threads || !thread_args || !flip_positions) {
            perror("Failed to allocate thread structures");
            free(mem);
            return 1;
        }
        
        // Create and start threads
        for (int i = 0; i < num_threads; i++) {
            // Calculate addresses for this thread
            // For each thread, we create a victim area between two hammering areas
            size_t thread_offset = i * pages_per_thread * PAGE_SIZE;
            void *hammer_addr1 = (char *)mem + thread_offset;
            void *victim_addr = (char *)mem + thread_offset + PAGE_SIZE;
            void *hammer_addr2 = (char *)mem + thread_offset + 2 * PAGE_SIZE;
            
            // Fill the thread arguments
            thread_args[i].addr1 = hammer_addr1;
            thread_args[i].addr2 = hammer_addr2;
            thread_args[i].iterations = iterations;
            thread_args[i].thread_id = i;
            thread_args[i].flip_count = &total_flips;
            thread_args[i].flip_positions = flip_positions;
            thread_args[i].num_flip_positions = &num_flip_positions;
            thread_args[i].verify = verify_mode;
            thread_args[i].victim_area = victim_addr;
            thread_args[i].victim_size = PAGE_SIZE;
            thread_args[i].expected_pattern = PATTERNS[pattern_index][0];
            
            // Start the thread
            if (pthread_create(&threads[i], NULL, hammer_thread, &thread_args[i]) != 0) {
                perror("Failed to create thread");
                free(mem);
                free(threads);
                free(thread_args);
                return 1;
            }
        }
        
        // Wait for all threads to complete
        uint64_t start_time = get_timestamp_ms();
        for (int i = 0; i < num_threads; i++) {
            pthread_join(threads[i], NULL);
        }
        uint64_t end_time = get_timestamp_ms();
        
        // Print results for this run
        printf("\n=== Row Hammer Results (Run %d/%d) ===\n", run + 1, runs);
        printf("Total execution time: %lu ms\n", end_time - start_time);
        printf("Memory accesses per second: %.2f million\n", 
               (double)iterations * num_threads * 2 / ((end_time - start_time) / 1000.0) / 1000000.0);
        
        if (verify_mode) {
            printf("Total bit flips detected: %lu\n", total_flips);
            if (total_flips > 0) {
                printf("!!! ROW HAMMER SUCCESSFUL - MEMORY CORRUPTION DETECTED !!!\n");
            } else {
                printf("No bit flips detected in this run.\n");
            }
        }
        
        // Store results for consistency check
        if (run_consistency_check) {
            all_flip_counts[run] = num_flip_positions;
        }
        total_flips_all_runs += total_flips;
        
        // Run refresh test if requested
        if (run_refresh_test && total_flips > 0) {
            perform_refresh_test(mem, mem_size, flip_positions, num_flip_positions, 
                               PATTERNS[pattern_index][0]);
        }
        
        // Clean up this run
        free(threads);
        free(thread_args);
        if (!run_consistency_check) {
            free(flip_positions);
        }
        free(mem);
    }
    
    // After all runs, check consistency if requested
    if (run_consistency_check && total_flips_all_runs > 0) {
        printf("\n=== Consistency Check Results ===\n");
        bool consistent = verify_consistent_flips(all_flip_positions, all_flip_counts, runs);
        printf("Bit flip locations are %s across all %d runs\n", 
               consistent ? "CONSISTENT" : "INCONSISTENT", runs);
        
        if (consistent) {
            printf("The consistent nature of these flips suggests hardware vulnerability.\n");
            printf("This memory module is likely VULNERABLE to Row Hammer attacks.\n");
        } else {
            printf("The inconsistent nature of these flips suggests either:\n");
            printf("1. Random noise or environmental factors rather than true Row Hammer, or\n");
            printf("2. Probabilistic Row Hammer that depends on access patterns/timing\n");
        }
    }
    
    // Final cleanup
    if (run_consistency_check) {
        for (int i = 0; i < runs; i++) {
            free(all_flip_positions[i]);
        }
        free(all_flip_positions);
        free(all_flip_counts);
    }
    
    return 0;
}