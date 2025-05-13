#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <x86intrin.h> // For _mm_clflush, _mm_mfence, _mm_sfence
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <getopt.h> // For command line argument parsing

// Define access patterns
typedef enum {
    ACCESS_SEQ,
    ACCESS_RAND,
    ACCESS_STRIDE,
    ACCESS_VICTIM_AGGRESSOR // Conceptual, needs specific implementation
} access_pattern_t;

// Define cache flush modes
typedef enum {
    CACHE_FLUSH_NONE,
    CACHE_FLUSH_LINES, // Flush accessed lines
    CACHE_FLUSH_ALL    // Attempt to flush entire cache (difficult, often not truly possible from user space)
} cache_flush_t;

typedef struct {
    size_t reps;
    size_t row_size;
    size_t distance;
    size_t pattern_length;
    uint8_t check_corruption;
    uint8_t perform_write;
    uint8_t verbose;
    size_t thread_count;
    access_pattern_t access_pattern;
    cache_flush_t cache_flush_mode;
    uint32_t random_seed;
} hammer_config_t;

typedef struct {
    void *mem_region;
    size_t mem_region_size;
    size_t offset_in_region; // Offset for this thread's operations within mem_region
    hammer_config_t *config;
    uint8_t *ref_data; // Pointer to the base of the reference data for the entire region
    uint8_t *corruption_detected_flag; // Shared flag among threads
    int thread_id;
} hammer_thread_data_t;

uint64_t get_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// Simple pseudo-random number generator (for rand access pattern)
uint32_t prng_state;
void init_prng(uint32_t seed) {
    prng_state = seed;
}
uint32_t simple_rand() {
    prng_state = (1103515245 * prng_state + 12345) & 0x7FFFFFFF;
    return prng_state;
}


void *hammer_thread(void *arg) {
    hammer_thread_data_t *data = (hammer_thread_data_t *)arg;
    hammer_config_t *cfg = data->config;

    volatile uint8_t *base_addr = (uint8_t *)data->mem_region + data->offset_in_region;
    size_t current_op_count = 0;

    // For stride and victim/aggressor, more complex address generation is needed.
    // This is a simplified example.
    size_t max_offset = data->mem_region_size - data->offset_in_region - cfg->row_size;
    if (cfg->pattern_length > 0 && cfg->distance > 0) {
         max_offset = cfg->pattern_length * cfg->distance;
         if (max_offset > data->mem_region_size - data->offset_in_region - cfg->row_size) {
            max_offset = data->mem_region_size - data->offset_in_region - cfg->row_size;
         }
    }


    for (size_t i = 0; i < cfg->reps; i++) {
        for (size_t p_idx = 0; p_idx < cfg->pattern_length; ++p_idx) {
            volatile uint64_t *target_addr;
            size_t current_byte_offset = 0;

            switch (cfg->access_pattern) {
                case ACCESS_SEQ:
                    current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1);
                    break;
                case ACCESS_RAND:
                    current_byte_offset = simple_rand() % (max_offset + 1);
                    current_byte_offset -= current_byte_offset % sizeof(uint64_t); // Align to 64-bit
                    break;
                case ACCESS_STRIDE: // Example: stride by distance
                    current_byte_offset = (current_op_count * cfg->distance) % (max_offset + 1);
                    break;
                case ACCESS_VICTIM_AGGRESSOR:
                    // This would require a more complex setup, e.g., two aggressor rows
                    // sandwiching a victim row. For simplicity, falls back to sequential.
                    current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1);
                    break;
                default:
                    current_byte_offset = (p_idx * cfg->distance) % (max_offset + 1);
            }
            target_addr = (volatile uint64_t *)(base_addr + current_byte_offset);

            if (cfg->cache_flush_mode == CACHE_FLUSH_LINES) {
                _mm_clflush((const void *)target_addr);
            }

            if (cfg->perform_write) {
                *target_addr = i + p_idx; // Write operation
            } else {
                volatile uint64_t dummy = *target_addr; // Read operation
                (void)dummy;
            }
            _mm_mfence(); // Memory fence
            current_op_count++;
        }

        if (cfg->cache_flush_mode == CACHE_FLUSH_ALL) {
            // Note: True full cache flush from user space is hard.
            // This is a placeholder; _mm_mfence might be the best we can do generally,
            // or use a large memory sweep if trying to evict.
            _mm_mfence();
        }
         _mm_sfence(); // Store fence after writes

        if (cfg->check_corruption && data->ref_data && !(*data->corruption_detected_flag) && (i % 10000 == 0)) { // Check less frequently
            for (size_t p_idx = 0; p_idx < cfg->pattern_length; ++p_idx) {
                 size_t check_offset = (p_idx * cfg->distance) % (max_offset + 1);
                 // Check first few bytes of the "row" (simplified)
                 for (size_t k=0; k < sizeof(uint64_t) && (data->offset_in_region + check_offset + k) < data->mem_region_size; ++k) {
                    uint8_t expected = data->ref_data[data->offset_in_region + check_offset + k];
                    uint8_t actual = ((uint8_t*)data->mem_region)[data->offset_in_region + check_offset + k];
                    if (cfg->perform_write && expected != actual) { // Only check if we wrote
                        // This check is tricky because we are writing 'i+p_idx'.
                        // A proper check would re-initialize ref_data or compare against expected write values.
                        // For simplicity, if perform_write is on, this check is less meaningful with current write pattern.
                        // If perform_write is OFF, then ref_data should match.
                    } else if (!cfg->perform_write && expected != actual) {
                         *data->corruption_detected_flag = 1;
                         if(cfg->verbose) printf("[Thread %d] Corruption at mem_offset %p (expected %02x, got %02x)\n",
                               data->thread_id,
                               (void*)(base_addr + check_offset + k),
                               expected, actual);
                        goto end_thread_loop; // Exit if corruption found
                    }
                 }
            }
        }
    }
end_thread_loop:
    return NULL;
}

void print_usage(char *argv0) {
    printf("NSR-AM Memory Hammer v2.2 - System-Level Analogy for Transistor Stress\n");
    printf("Usage: %s [options]\n", argv0);
    printf("Options:\n");
    printf("  --reps N              Hammering iterations (Default: 20M)\n");
    printf("  --row-size N          Memory row size (page size, Default: 4096)\n");
    printf("  --distance N          Distance between addresses (Default: 8192)\n");
    printf("  --pattern-length N    Access pattern length (Default: 4)\n");
    printf("  --check-corruption N  Check for memory corruption 0/1 (Default: 1, only effective if --perform-write=0)\n");
    printf("  --perform-write N     Perform write operations 0/1 (Default: 1)\n");
    printf("  --thread-count N      Number of parallel threads (Default: 2)\n");
    printf("  --access-pattern STR  Access pattern: seq, rand, stride, victim (Default: seq)\n");
    printf("  --cache-flush STR     Cache flush: none, lines, all (Default: lines)\n");
    printf("  --seed N              Random seed for 'rand' pattern (Default: current time)\n");
    printf("  --verbose N           Verbose output 0/1 (Default: 1)\n");
    printf("  --help                Show this help\n");
}


int main(int argc, char *argv[]) {
    hammer_config_t config = {
        .reps = 2000000, .row_size = 4096, .distance = 8192, .pattern_length = 4,
        .check_corruption = 1, .perform_write = 1, .verbose = 1, .thread_count = 2,
        .access_pattern = ACCESS_SEQ, .cache_flush_mode = CACHE_FLUSH_LINES, .random_seed = (uint32_t)time(NULL)
    };

    static struct option long_options[] = {
        {"reps", required_argument, 0, 'r'}, {"row-size", required_argument, 0, 's'},
        {"distance", required_argument, 0, 'd'}, {"pattern-length", required_argument, 0, 'l'},
        {"check-corruption", required_argument, 0, 'c'}, {"perform-write", required_argument, 0, 'w'},
        {"thread-count", required_argument, 0, 't'}, {"access-pattern", required_argument, 0, 'a'},
        {"cache-flush", required_argument, 0, 'f'}, {"seed", required_argument, 0, 'e'},
        {"verbose", required_argument, 0, 'v'}, {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "r:s:d:l:c:w:t:a:f:e:v:h", long_options, NULL)) != -1) {
        switch (opt) {
            case 'r': config.reps = atoll(optarg); break;
            case 's': config.row_size = atoll(optarg); break;
            case 'd': config.distance = atoll(optarg); break;
            case 'l': config.pattern_length = atoll(optarg); break;
            case 'c': config.check_corruption = atoi(optarg); break;
            case 'w': config.perform_write = atoi(optarg); break;
            case 't': config.thread_count = atoi(optarg); break;
            case 'a':
                if (strcmp(optarg, "seq") == 0) config.access_pattern = ACCESS_SEQ;
                else if (strcmp(optarg, "rand") == 0) config.access_pattern = ACCESS_RAND;
                else if (strcmp(optarg, "stride") == 0) config.access_pattern = ACCESS_STRIDE;
                else if (strcmp(optarg, "victim") == 0) config.access_pattern = ACCESS_VICTIM_AGGRESSOR;
                else { fprintf(stderr, "Invalid access pattern: %s\n", optarg); return 1; }
                break;
            case 'f':
                if (strcmp(optarg, "none") == 0) config.cache_flush_mode = CACHE_FLUSH_NONE;
                else if (strcmp(optarg, "lines") == 0) config.cache_flush_mode = CACHE_FLUSH_LINES;
                else if (strcmp(optarg, "all") == 0) config.cache_flush_mode = CACHE_FLUSH_ALL;
                else { fprintf(stderr, "Invalid cache flush mode: %s\n", optarg); return 1; }
                break;
            case 'e': config.random_seed = atoi(optarg); break;
            case 'v': config.verbose = atoi(optarg); break;
            case 'h': print_usage(argv[0]); return 0;
            default: print_usage(argv[0]); return 1;
        }
    }
    init_prng(config.random_seed);


    size_t total_mem_size = config.row_size * config.pattern_length * config.thread_count * 2; // Ensure enough space
    if (total_mem_size == 0) total_mem_size = config.row_size * 10; // Min size

    void *mem_region = aligned_alloc(config.row_size, total_mem_size);
    if (!mem_region) { perror("Memory allocation failed"); return 1; }
    memset(mem_region, 0, total_mem_size); // Initialize

    uint8_t *ref_data_copy = NULL;
    if (config.check_corruption && !config.perform_write) { // Corruption check is most meaningful if not writing
        ref_data_copy = malloc(total_mem_size);
        if (!ref_data_copy) { perror("Ref data allocation failed"); free(mem_region); return 1; }
        for(size_t i=0; i < total_mem_size; ++i) ref_data_copy[i] = ((i * 37) + (i % 13)) & 0xFF; // Fill with a pattern
        memcpy(mem_region, ref_data_copy, total_mem_size);
    } else if (config.check_corruption && config.perform_write) {
        if(config.verbose) printf("WARN: Corruption check with perform_write=1 is complex and may not be accurate with this tool's simple check.\n");
    }


    if (config.verbose) {
        printf("NS-RAM Memory Hammer v2.2\nConfig: Reps=%zuM, PatternLen=%zu, WriteOps=%d, Threads=%zu, Access=%d, Flush=%d, Seed=%u, Mem=%zuMB\n",
               config.reps / 1000000, config.pattern_length, config.perform_write, config.thread_count,
               config.access_pattern, config.cache_flush_mode, config.random_seed, total_mem_size / (1024 * 1024));
    }

    pthread_t *threads = malloc(config.thread_count * sizeof(pthread_t));
    hammer_thread_data_t *thread_data_array = malloc(config.thread_count * sizeof(hammer_thread_data_t));
    uint8_t overall_corruption_detected = 0;

    uint64_t start_ns = get_ns();

    size_t per_thread_mem_span = total_mem_size / config.thread_count;

    for (size_t t = 0; t < config.thread_count; t++) {
        thread_data_array[t].mem_region = mem_region;
        thread_data_array[t].mem_region_size = total_mem_size; // Each thread knows total size
        thread_data_array[t].offset_in_region = t * per_thread_mem_span; // Threads operate on distinct (or overlapping if desired) parts
        thread_data_array[t].config = &config;
        thread_data_array[t].ref_data = ref_data_copy;
        thread_data_array[t].corruption_detected_flag = &overall_corruption_detected;
        thread_data_array[t].thread_id = t;
        pthread_create(&threads[t], NULL, hammer_thread, &thread_data_array[t]);
    }

    for (size_t t = 0; t < config.thread_count; t++) {
        pthread_join(threads[t], NULL);
    }

    uint64_t end_ns = get_ns();
    double elapsed_s = (end_ns - start_ns) / 1000000000.0;

    if (config.verbose) {
        printf("Results: Time=%.2fs, Rate=%.2f M iter/s\n", elapsed_s, (config.reps * config.thread_count) / elapsed_s / 1000000.0);
        if (config.check_corruption && !config.perform_write) { // Only report if meaningful
            printf("  STATUS: %s\n", overall_corruption_detected ? "CORRUPTION DETECTED" : "No corruption detected");
        }
    }

    free(mem_region);
    free(threads);
    free(thread_data_array);
    if (ref_data_copy) free(ref_data_copy);

    return overall_corruption_detected ? 2 : 0; // Return 2 if corruption, 0 otherwise
}
