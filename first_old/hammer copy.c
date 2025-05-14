#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

// Configuration struct for hammer parameters
typedef struct {
    size_t reps;             // Number of hammering iterations
    size_t row_size;         // Size of each memory row (usually 4096 for page size)
    size_t distance;         // Distance between hammered addresses
    size_t pattern_length;   // Length of the access pattern
    uint8_t check_corruption; // Whether to check for memory corruption
    uint8_t perform_write;   // Whether to perform writes (more aggressive)
    uint8_t verbose;         // Verbose output
    size_t thread_count;     // Number of threads to use
} hammer_config_t;

// Get time in nanoseconds (for timing measurements)
uint64_t get_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Thread data structure
typedef struct {
    void *mem_region;
    size_t offset;
    size_t pattern_length;
    size_t distance;
    size_t reps;
    uint8_t perform_write;
    uint8_t check_corruption;
    uint8_t *ref_data;
    uint8_t *corruption_detected;
} hammer_thread_data_t;

// Enhanced hammering function with various access patterns
void *hammer_thread(void *arg) {
    hammer_thread_data_t *data = (hammer_thread_data_t *)arg;
    
    // Create array of addresses to hammer based on pattern
    volatile uint64_t **addresses = malloc(data->pattern_length * sizeof(uint64_t*));
    for (size_t i = 0; i < data->pattern_length; i++) {
        addresses[i] = (uint64_t*)((char*)data->mem_region + data->offset + (i * data->distance));
    }
    
    // Alternate access pattern for more aggressive stress (NS-RAM analogy: multiple pulse patterns)
    int pattern_selector = 0;
    const int NUM_PATTERNS = 3;
    
    // Main hammering loop (NS-RAM analogy: pulse train with variable amplitudes)
    for (size_t i = 0; i < data->reps; i++) {
        // Change pattern every 1000 iterations to create variable stress (NS-RAM: pulse width/amplitude modulation)
        if (i % 1000 == 0) {
            pattern_selector = (pattern_selector + 1) % NUM_PATTERNS;
        }
        
        // Flush cache lines (NS-RAM analogy: depleting charge carriers)
        for (size_t j = 0; j < data->pattern_length; j++) {
            _mm_clflush((const void *)addresses[j]);
        }
        _mm_mfence(); // Ensure flush completes
        _mm_sfence(); // Store fence
        
        // Access pattern 0: Sequential (NS-RAM: regular pulse train)
        if (pattern_selector == 0) {
            for (size_t j = 0; j < data->pattern_length; j++) {
                if (data->perform_write) {
                    *(addresses[j]) = i; // Write operation (NS-RAM: stronger pulse)
                } else {
                    volatile uint64_t dummy = *(addresses[j]); // Read operation (NS-RAM: weaker pulse)
                    (void)dummy; // Prevent optimization
                }
                _mm_mfence();
            }
        }
        // Access pattern 1: Alternating (NS-RAM: bipolar pulse)
        else if (pattern_selector == 1) {
            for (size_t j = 0; j < data->pattern_length; j += 2) {
                if (j+1 < data->pattern_length) {
                    if (data->perform_write) {
                        *(addresses[j]) = i;
                        *(addresses[j+1]) = ~i; // Inverted value (NS-RAM: bipolar pulse) 
                    } else {
                        volatile uint64_t dummy1 = *(addresses[j]);
                        volatile uint64_t dummy2 = *(addresses[j+1]);
                        (void)dummy1; (void)dummy2;
                    }
                    _mm_mfence();
                }
            }
        }
        // Access pattern 2: Reverse (NS-RAM: reverse pulse train)
        else {
            for (int j = data->pattern_length - 1; j >= 0; j--) {
                if (data->perform_write) {
                    *(addresses[j]) = i;
                } else {
                    volatile uint64_t dummy = *(addresses[j]);
                    (void)dummy;
                }
                _mm_mfence();
            }
        }
        
        // Check for corruption (NS-RAM analogy: detecting state changes)
        if (data->check_corruption && data->ref_data && data->corruption_detected && (i % 100000 == 0)) {
            for (size_t j = 0; j < data->pattern_length; j++) {
                for (size_t k = 0; k < 64; k += 8) { // Check first 64 bytes of each page
                    uint8_t expected = data->ref_data[data->offset + j * data->distance + k];
                    uint8_t actual = ((uint8_t*)data->mem_region)[data->offset + j * data->distance + k];
                    if (expected != actual && !(*data->corruption_detected)) {
                        *data->corruption_detected = 1;
                        printf("[Thread %zu] Corruption at %p: Expected %u, got %u\n", 
                              data->offset/data->distance, 
                              (void*)((uint8_t*)data->mem_region + data->offset + j * data->distance + k),
                              expected, actual);
                    }
                }
            }
        }
    }
    
    free(addresses);
    return NULL;
}

int main(int argc, char *argv[]) {
    // Default configuration (NS-RAM analogy: base transistor parameters)
    hammer_config_t config = {
        .reps = 20000000,          // Higher iteration count (NS-RAM: longer stress cycles)
        .row_size = 4096,          // Page size (NS-RAM: transistor geometry)
        .distance = 8192,          // Doubled distance between addresses (NS-RAM: wider spacing)
        .pattern_length = 4,       // Increased pattern length (NS-RAM: multi-cell effects)
        .check_corruption = 1,     // Check for bit flips (NS-RAM: state transitions)
        .perform_write = 1,        // More aggressive with writes (NS-RAM: stronger pulses)
        .verbose = 1,
        .thread_count = 2          // Multi-threaded (NS-RAM: parallel cell operation)
    };
    
    // Parse command-line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--reps") == 0 && i+1 < argc) {
            config.reps = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--row-size") == 0 && i+1 < argc) {
            config.row_size = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--distance") == 0 && i+1 < argc) {
            config.distance = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--pattern-length") == 0 && i+1 < argc) {
            config.pattern_length = atoll(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--check-corruption") == 0 && i+1 < argc) {
            config.check_corruption = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--perform-write") == 0 && i+1 < argc) {
            config.perform_write = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--thread-count") == 0 && i+1 < argc) {
            config.thread_count = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--verbose") == 0 && i+1 < argc) {
            config.verbose = atoi(argv[i+1]); i++;
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("NSR-AM Memory Hammer v2.0 - System-Level Analogy for Transistor Stress\n");
            printf("Usage: %s [options]\n", argv[0]);
            printf("Options:\n");
            printf("  --reps N              Hammering iterations (Default: 20M)\n");
            printf("  --row-size N          Memory row size in bytes (Default: 4096)\n");
            printf("  --distance N          Distance between addresses (Default: 8192)\n");
            printf("  --pattern-length N    Access pattern length (Default: 4)\n");
            printf("  --check-corruption N  Check for memory corruption 0/1 (Default: 1)\n");
            printf("  --perform-write N     Perform write operations 0/1 (Default: 1)\n");
            printf("  --thread-count N      Number of parallel threads (Default: 2)\n");
            printf("  --verbose N           Verbose output 0/1 (Default: 1)\n");
            return 0;
        }
    }
    
    // Calculate total memory size needed
    size_t total_size = config.row_size * config.pattern_length * config.thread_count * 2;
    
    // Allocate and initialize memory
    void *mem = aligned_alloc(config.row_size, total_size);
    if (!mem) {
        perror("Memory allocation failed");
        return 1;
    }
    
    // Initialize test pattern and reference copy
    uint8_t *ref_data = NULL;
    if (config.check_corruption) {
        ref_data = malloc(total_size);
        if (!ref_data) {
            perror("Reference data allocation failed");
            free(mem);
            return 1;
        }
        
        // Create pattern with recognizable data
        for (size_t i = 0; i < total_size; i++) {
            ref_data[i] = ((i * 37) & 0xFF);  // Easily detectable pattern
            ((uint8_t*)mem)[i] = ref_data[i]; // Copy to main memory
        }
    }
    
    if (config.verbose) {
        printf("NS-RAM Memory Hammer v2.0\n");
        printf("-------------------------\n");
        printf("Configuration:\n");
        printf("  Repetitions: %zu million\n", config.reps / 1000000);
        printf("  Pattern length: %zu addresses\n", config.pattern_length);
        printf("  Write operations: %s\n", config.perform_write ? "Enabled" : "Disabled");
        printf("  Threads: %zu\n", config.thread_count);
        printf("  Memory allocated: %zu MB\n", total_size / (1024*1024));
    }
    
    // Create and launch threads
    pthread_t *threads = malloc(config.thread_count * sizeof(pthread_t));
    hammer_thread_data_t *thread_data = malloc(config.thread_count * sizeof(hammer_thread_data_t));
    uint8_t corruption_detected = 0;
    
    uint64_t start_ns = get_ns();
    
    for (size_t t = 0; t < config.thread_count; t++) {
        thread_data[t].mem_region = mem;
        thread_data[t].offset = t * config.pattern_length * config.distance;
        thread_data[t].pattern_length = config.pattern_length;
        thread_data[t].distance = config.distance;
        thread_data[t].reps = config.reps;
        thread_data[t].perform_write = config.perform_write;
        thread_data[t].check_corruption = config.check_corruption;
        thread_data[t].ref_data = ref_data;
        thread_data[t].corruption_detected = &corruption_detected;
        
        pthread_create(&threads[t], NULL, hammer_thread, &thread_data[t]);
    }
    
    // Wait for all threads to complete
    for (size_t t = 0; t < config.thread_count; t++) {
        pthread_join(threads[t], NULL);
    }
    
    uint64_t end_ns = get_ns();
    double elapsed_s = (end_ns - start_ns) / 1000000000.0;
    
    if (config.verbose) {
        printf("\nResults:\n");
        printf("  Execution time: %.2f seconds\n", elapsed_s);
        printf("  Hammer rate: %.2f million iterations/sec\n", config.reps / elapsed_s / 1000000.0);
        
        if (config.check_corruption) {
            if (corruption_detected) {
                printf("  STATUS: CORRUPTION DETECTED\n");
                printf("  Analog: Memory state transition observed (comparable to NS-RAM state change)\n");
            } else {
                printf("  STATUS: No corruption detected\n");
                printf("  Analog: Memory maintained stable state (comparable to sub-threshold NS-RAM))\n");
            }
        }
    }
    
    // Clean up
    free(mem);
    free(threads);
    free(thread_data);
    if (ref_data) free(ref_data);
    
    return corruption_detected ? 2 : 0;
}
