// Enhanced Rowhammer-like memory stressor
// Inspired by concepts of inducing fault states to observe analog-like behaviors
// in digital systems, as discussed in neuromorphic computing analogies.
#define _GNU_SOURCE // For CPU_SET, CPU_ZERO, pthread_setaffinity_np
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h> // For _mm_clflush and _mm_mfence
#include <unistd.h>    // For sysconf
#include <pthread.h>
#include <time.h>
#include <sys/mman.h> // For mmap-related constants if needed, sysconf
#include <sched.h>    // For pthread_setaffinity_np

// Default configuration values
#define DEFAULT_REPS 100000000ULL
#define DEFAULT_VICTIM_SIZE 8192
#define DEFAULT_AGGRESSOR_OFFSET 8192
// Set default thread count to number of online processors, fallback to 4
long nproc_online; // Global to store nproc result
#define GET_DEFAULT_THREAD_COUNT() (nproc_online = sysconf(_SC_NPROCESSORS_ONLN), (nproc_online > 0 ? (size_t)nproc_online : 4))
#define DEFAULT_SCAN_STEP_DIVISOR 1
#define DEFAULT_MEMORY_MB 128
#define DEFAULT_STOP_ON_FIRST_FLIP 0
#define DEFAULT_SET_AFFINITY 1 // Enable thread affinity by default

// Configuration structure to hold all parameters
typedef struct {
    size_t reps;
    size_t victim_region_size;
    size_t aggressor_offset;
    size_t thread_count;
    size_t scan_step_divisor;
    size_t total_memory_mb;
    int stop_on_first_flip;
    int set_affinity;
    // Derived values
    size_t scan_step;
    size_t total_memory_to_allocate;
    size_t alignment;
    long num_available_cores;
} config_t;

// Arguments for each hammer thread
typedef struct {
    volatile uint8_t *addr1;
    volatile uint8_t *addr2;
    size_t reps;
    int thread_id;
    const config_t *config; // Pointer to global config for affinity
} hammer_args_t;


// Function to get current time in nanoseconds for measurements
uint64_t get_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// The core hammering function: repeatedly accesses two aggressor addresses
// This intense, localized activity is analogous to repeatedly stimulating specific pathways,
// potentially leading to a "threshold" being crossed in victim cells (bit flip).
void hammer_row(volatile uint8_t *addr1, volatile uint8_t *addr2, size_t reps) {
    for (size_t i = 0; i < reps; i++) {
        // Volatile reads to ensure the compiler doesn't optimize them away.
        // Accessing a wider type (like uint64_t) can sometimes be more effective
        // at activating the DRAM row than a single byte access.
        *(volatile uint64_t*)addr1;
        *(volatile uint64_t*)addr2;

        // Flush aggressor addresses from cache to force DRAM access.
        // This is critical for Rowhammer-like effects, ensuring direct DRAM interaction.
        _mm_clflush((const void *)addr1);
        _mm_clflush((const void *)addr2);

        // Memory fence to ensure flushes complete and memory operations are ordered.
        _mm_mfence();
    }
}

// Thread function that calls hammer_row
void *hammer_thread(void *args_ptr) {
    hammer_args_t *hargs = (hammer_args_t *)args_ptr;
    const config_t *cfg = hargs->config;

    if (cfg->set_affinity && cfg->thread_count > 0 && cfg->num_available_cores > 0) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        // Simple modulo distribution of threads to cores
        CPU_SET(hargs->thread_id % cfg->num_available_cores, &cpuset);
        if (pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset) != 0) {
            perror("Warning: Could not set thread affinity");
            // Continue without affinity if it fails
        }
    }

    hammer_row(hargs->addr1, hargs->addr2, hargs->reps);
    return NULL;
}

// Helper to parse string to size_t, with error checking
size_t parse_size_t(const char *str, const char *arg_name, int allow_zero_for_this_param) {
    char *endptr;
    unsigned long long val = strtoull(str, &endptr, 10);
    if (endptr == str || *endptr != '\0') {
        fprintf(stderr, "Error: Invalid number for %s: %s\n", arg_name, str);
        exit(EXIT_FAILURE);
    }
    if (!allow_zero_for_this_param && val == 0) {
        fprintf(stderr, "Error: Zero value not allowed for %s: %s\n", arg_name, str);
        exit(EXIT_FAILURE);
    }
    return (size_t)val;
}

void print_usage(char *argv0) {
    printf("Usage: %s [options]\n", argv0);
    printf("Enhanced Rowhammer-like Memory Stressor\n");
    printf("Attempts to induce bit flips by repeatedly accessing memory, analogous to stressing neuro-synaptic elements.\n\n");
    printf("Options:\n");
    printf("  --reps N                Repetitions per thread/region (default: %llu)\n", (unsigned long long)DEFAULT_REPS);
    printf("  --victim-size N         Size of victim region to check (bytes, default: %u)\n", DEFAULT_VICTIM_SIZE);
    printf("  --aggressor-offset N    Offset of aggressor addrs from victim start (bytes, default: %u)\n", DEFAULT_AGGRESSOR_OFFSET);
    printf("  --threads N             Number of hammering threads (default: %ld or 4 if detection fails)\n", nproc_online > 0 ? nproc_online : 4);
    printf("  --scan-step-divisor N   Victim scan step = victim-size / N (default: %u; 1 for non-overlapping)\n", DEFAULT_SCAN_STEP_DIVISOR);
    printf("  --memory-mb N           Total memory to allocate for scanning (MB, default: %u)\n", DEFAULT_MEMORY_MB);
    printf("  --set-affinity <0|1>    Set thread affinity (default: %d, 1=yes, 0=no)\n", DEFAULT_SET_AFFINITY);
    printf("  --stop-on-first-flip    Stop after the first bit flip is detected (flag, no argument)\n");
    printf("  --help                  Show this help message\n");
}


int main(int argc, char **argv) {
    config_t config;
    config.reps = DEFAULT_REPS;
    config.victim_region_size = DEFAULT_VICTIM_SIZE;
    config.aggressor_offset = DEFAULT_AGGRESSOR_OFFSET;
    config.thread_count = GET_DEFAULT_THREAD_COUNT(); // Initialize with dynamic default
    config.scan_step_divisor = DEFAULT_SCAN_STEP_DIVISOR;
    config.total_memory_mb = DEFAULT_MEMORY_MB;
    config.stop_on_first_flip = DEFAULT_STOP_ON_FIRST_FLIP;
    config.set_affinity = DEFAULT_SET_AFFINITY;
    config.num_available_cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (config.num_available_cores <= 0) config.num_available_cores = 1; // Fallback for affinity calculation


    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--reps") == 0 && i + 1 < argc) config.reps = parse_size_t(argv[++i], "--reps", 0);
        else if (strcmp(argv[i], "--victim-size") == 0 && i + 1 < argc) config.victim_region_size = parse_size_t(argv[++i], "--victim-size", 0);
        else if (strcmp(argv[i], "--aggressor-offset") == 0 && i + 1 < argc) config.aggressor_offset = parse_size_t(argv[++i], "--aggressor-offset", 0);
        else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) config.thread_count = parse_size_t(argv[++i], "--threads", 0);
        else if (strcmp(argv[i], "--scan-step-divisor") == 0 && i + 1 < argc) config.scan_step_divisor = parse_size_t(argv[++i], "--scan-step-divisor", 0);
        else if (strcmp(argv[i], "--memory-mb") == 0 && i + 1 < argc) config.total_memory_mb = parse_size_t(argv[++i], "--memory-mb", 0);
        else if (strcmp(argv[i], "--set-affinity") == 0 && i + 1 < argc) config.set_affinity = atoi(argv[++i]);
        else if (strcmp(argv[i], "--stop-on-first-flip") == 0) config.stop_on_first_flip = 1;
        else if (strcmp(argv[i], "--help") == 0) { print_usage(argv[0]); return 0; }
        else { fprintf(stderr, "Unknown option: %s\n", argv[i]); print_usage(argv[0]); return 1; }
    }

    if (config.scan_step_divisor == 0) config.scan_step_divisor = 1; // Avoid division by zero
    config.scan_step = config.victim_region_size / config.scan_step_divisor;
    if (config.scan_step == 0 && config.victim_region_size > 0) config.scan_step = 1;
    else if (config.victim_region_size == 0) {fprintf(stderr, "Error: victim-size cannot be 0.\n"); return 1;}
    if (config.aggressor_offset == 0) {fprintf(stderr, "Error: aggressor-offset cannot be 0.\n"); return 1;}
    if (config.thread_count == 0) {fprintf(stderr, "Error: thread-count cannot be 0.\n"); return 1;}
    if (config.reps == 0) {fprintf(stderr, "Error: reps cannot be 0.\n"); return 1;}
    if (config.total_memory_mb == 0) {fprintf(stderr, "Error: memory-mb cannot be 0.\n"); return 1;}


    config.alignment = 2 * 1024 * 1024; // 2MB for trying to use huge pages
    config.total_memory_to_allocate = config.total_memory_mb * 1024 * 1024;

    if (config.total_memory_to_allocate < (config.aggressor_offset * 2 + config.victim_region_size)) { // Ensure enough space for one full setup
        fprintf(stderr, "Error: Total memory allocated (%zu MB) is too small for one test setup (victim size %zu, aggressor offset %zu).\n",
                config.total_memory_mb, config.victim_region_size, config.aggressor_offset);
        return 1;
    }
    if (config.total_memory_to_allocate < config.alignment) {
         fprintf(stderr, "Warning: Total memory (%zu MB) is less than desired alignment (%zu MB). Proceeding without rounding up to alignment.\n",
                 config.total_memory_mb, config.alignment / (1024*1024));
    } else {
        config.total_memory_to_allocate = ((config.total_memory_to_allocate + config.alignment - 1) / config.alignment) * config.alignment; // Round up to alignment boundary
    }


    printf("Hammer Config: Reps/Thread/Region=%zu, VictimSize=%zu, AggressorOffset=%zu, Threads=%zu, ScanStep=%zu, TotalMem=%.2fMB, Affinity=%d, StopOnFirstFlip=%d\n",
           config.reps, config.victim_region_size, config.aggressor_offset, config.thread_count, config.scan_step,
           (double)config.total_memory_to_allocate / (1024.0 * 1024.0), config.set_affinity, config.stop_on_first_flip);

    uint8_t *mem_base = (uint8_t*)aligned_alloc(config.alignment, config.total_memory_to_allocate);
    if (!mem_base) {
        perror("aligned_alloc failed for large buffer");
        return 1;
    }
    printf("Allocated %.2f MB at %p. Initializing entire buffer to a background pattern (0xA5)...\n", (double)config.total_memory_to_allocate / (1024.0 * 1024.0), (void*)mem_base);
    memset(mem_base, 0xA5, config.total_memory_to_allocate);
    printf("Memory initialized.\n");

    pthread_t *threads = (pthread_t*)malloc(config.thread_count * sizeof(pthread_t));
    hammer_args_t *args = (hammer_args_t*)malloc(config.thread_count * sizeof(hammer_args_t));
    if (!threads || !args) {
        perror("Failed to allocate thread structures");
        free(mem_base);
        return 1;
    }

    int overall_bit_flip_detected = 0;
    uint64_t total_start_time = get_ns();
    size_t regions_tested_count = 0;
    size_t flips_found_total = 0;

    // Iterate through the allocated memory, selecting victim regions
    // Start victim scan far enough from the beginning to allow for agg1.
    // End victim scan early enough to allow for agg2 and full victim region.
    size_t max_victim_start_offset = 0;
    if (config.total_memory_to_allocate > config.aggressor_offset + config.victim_region_size) { // Ensure no underflow
        max_victim_start_offset = config.total_memory_to_allocate - config.victim_region_size;
        if (max_victim_start_offset > config.aggressor_offset) { // Ensure agg2 doesn't go out of bounds
             max_victim_start_offset -= config.aggressor_offset;
        } else { // Not enough space for even one aggressor on the other side if victim starts at max_victim_start_offset
            max_victim_start_offset = config.aggressor_offset; // Will make loop condition false if not enough space
        }
    }


    for (size_t current_victim_start_offset = config.aggressor_offset;
         current_victim_start_offset <= max_victim_start_offset;
         current_victim_start_offset += config.scan_step) {

        if (current_victim_start_offset + config.victim_region_size > config.total_memory_to_allocate) break; // Double check victim region end
        if (current_victim_start_offset + config.aggressor_offset + sizeof(uint64_t) > config.total_memory_to_allocate) break; // Double check aggressor2 end

        regions_tested_count++;
        volatile uint8_t *victim_addr = mem_base + current_victim_start_offset;
        volatile uint8_t *p_agg_row1 = victim_addr - config.aggressor_offset;
        volatile uint8_t *p_agg_row2 = victim_addr + config.aggressor_offset;

        // Re-initialize the current victim region to 0xFF right before testing it.
        // This is the "charge" or "integration" phase for our analogical memory neuron.
        memset((void*)victim_addr, 0xFF, config.victim_region_size);

        // Print progress periodically or if reps are very high (indicative of a long run per region)
        if (regions_tested_count % 100 == 1 || config.reps > 200000000ULL) {
             printf("Region %zu: Testing Victim @ %p (Offset from base: 0x%zx). Aggressors: %p (-%zu), %p (+%zu)\n",
                   regions_tested_count, (void*)victim_addr, (size_t)(victim_addr - mem_base),
                   (void*)p_agg_row1, config.aggressor_offset, (void*)p_agg_row2, config.aggressor_offset);
        }

        uint64_t region_start_time = get_ns();
        for (size_t t = 0; t < config.thread_count; t++) {
            args[t].addr1 = p_agg_row1;
            args[t].addr2 = p_agg_row2;
            args[t].reps = config.reps; // Each thread does the full 'reps' for this region
            args[t].thread_id = t;
            args[t].config = &config; // Pass config for affinity
            if (pthread_create(&threads[t], NULL, hammer_thread, &args[t]) != 0) {
                perror("pthread_create failed");
                // Attempt to join/cancel already created threads before exiting
                for(size_t k=0; k<t; ++k) {
                    pthread_cancel(threads[k]); // Request cancellation
                    pthread_join(threads[k], NULL); // Wait for them
                }
                free(threads); free(args); free(mem_base);
                return 1;
            }
        }

        for (size_t t = 0; t < config.thread_count; t++) {
            pthread_join(threads[t], NULL);
        }
        uint64_t region_end_time = get_ns();

        int region_bit_flip_detected_this_pass = 0;
        for (size_t i = 0; i < config.victim_region_size; i++) {
            if (victim_addr[i] != 0xFF) {
                // This is analogous to the "neuron firing" or a "synapse changing state" due to stress.
                printf("\n!!! BIT FLIP DETECTED (Region %zu) !!!\n", regions_tested_count);
                printf("  Victim Region Start Absolute: %p, Relative Offset from mem_base: 0x%zx\n", (void*)victim_addr, (size_t)(victim_addr - mem_base));
                printf("  Flipped Byte Address Absolute: %p (Offset within victim: %zu)\n", (void*)&victim_addr[i], i);
                printf("  Original: 0xFF, Actual: 0x%02X\n", victim_addr[i]);
                printf("  Hammering time for this region: %.3f s\n", (region_end_time - region_start_time) / 1000000000.0);
                flips_found_total++;
                region_bit_flip_detected_this_pass = 1;
                overall_bit_flip_detected = 1;
                if (config.stop_on_first_flip) break;
            }
        }

        if (region_bit_flip_detected_this_pass && config.stop_on_first_flip) {
            printf("Stopping scan due to --stop-on-first-flip.\n");
            break;
        }
    }

    uint64_t total_end_time = get_ns();
    double total_elapsed_s = (total_end_time - total_start_time) / 1000000000.0;
    printf("\n--- Test Summary ---\n");
    printf("Tested %zu regions in %.2f seconds.\n", regions_tested_count, total_elapsed_s);
    printf("Total bit flips detected: %zu\n", flips_found_total);

    if (overall_bit_flip_detected) {
        printf("Overall Status: BIT FLIPS DETECTED!\n");
    } else {
        printf("Overall Status: No bit flips detected in any tested region with current parameters.\n");
    }

    free(threads);
    free(args);
    free(mem_base);
    return overall_bit_flip_detected ? 1 : 0; // Exit code 1 if flips found, 0 otherwise
}