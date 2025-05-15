#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <x86intrin.h>
#include <pthread.h>
#include <sched.h>
#include <math.h>

#define REGION_SIZE     (64 * 1024 * 1024) // 64MB
#define PATTERN         0xAA
#define HAMMER_ROUNDS   50000000           // More aggressive
#define THREADS         4
#define HAMMER_STRIDE   32
#define HAMMER_SPAN     0x8000             // 32KB hammer range

uint8_t* region;
FILE* logfile;

void log_event(const char* type, size_t offset, uint8_t expected, uint8_t actual, int delta_bits) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(logfile, "%s,%ld.%09ld,0x%zx,0x%02x,0x%02x,%d\n",
            type, ts.tv_sec, ts.tv_nsec, offset, expected, actual, delta_bits);
    fflush(logfile);
}

double calculate_entropy(uint8_t* mem, size_t len) {
    int freq[256] = {0};
    for (size_t i = 0; i < len; i++) freq[mem[i]]++;
    double entropy = 0.0;
    for (int i = 0; i < 256; i++) {
        if (freq[i]) {
            double p = (double)freq[i] / len;
            entropy -= p * log2(p);
        }
    }
    return entropy;
}

void* hammer_thread(void* arg) {
    size_t base = *(size_t*)arg;

    // CPU pinning
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(pthread_self() % sysconf(_SC_NPROCESSORS_ONLN), &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);

    uint8_t* row1 = region + base;
    uint8_t* row2 = region + base + HAMMER_SPAN;

    for (int i = 0; i < HAMMER_ROUNDS / THREADS; i++) {
        for (int offset = 0; offset < HAMMER_SPAN; offset += HAMMER_STRIDE) {
            uint8_t* a = row1 + offset;
            uint8_t* b = row2 + offset;
            _mm_clflush(a);
            _mm_clflush(b);
            *(volatile uint8_t*)a;
            *(volatile uint8_t*)b;
        }
        _mm_mfence();
    }
    return NULL;
}

void decay_test(uint8_t* mem, size_t len, int* phases, int phase_count) {
    for (int i = 0; i < phase_count; i++) {
        printf("[*] Decay Phase %d: waiting %d seconds...\n", i, phases[i]);
        sleep(phases[i]);

        int decay_errors = 0;
        for (size_t j = 0; j < len; j++) {
            if (mem[j] != PATTERN) {
                int delta = __builtin_popcount(mem[j] ^ PATTERN);
                decay_errors++;
                log_event("DECAY", j, PATTERN, mem[j], delta);
            }
        }
        double ent = calculate_entropy(mem, len);
        fprintf(logfile, "ENTROPY,%d,%.4f\n", phases[i], ent);
        fflush(logfile);

        printf("[+] Phase %d complete: %d decay errors, entropy = %.4f\n", i, decay_errors, ent);
    }
}

int main(int argc, char** argv) {
    printf("[*] Ultra-Aggressive DRAM Neuromorphic Test\n");
    srand(time(NULL));

    region = aligned_alloc(4096, REGION_SIZE);
    if (!region) {
        perror("alloc");
        return 1;
    }

    logfile = fopen("dram_aggressive_log.csv", "w");
    if (!logfile) {
        perror("log open");
        return 1;
    }
    fprintf(logfile, "event,timestamp,offset,expected,actual,delta_bits\n");

    printf("[*] Writing pattern 0x%02X to memory...\n", PATTERN);
    memset(region, PATTERN, REGION_SIZE);
    fprintf(logfile, "ENTROPY,0,%.4f\n", calculate_entropy(region, REGION_SIZE));

    int phases[] = {2, 5, 10};
    decay_test(region, REGION_SIZE, phases, 3);

    printf("[*] Optional thermal stress phase...\n");
    (void)system("stress-ng --cpu 4 --timeout 15s > /dev/null");

    printf("[*] Starting hammering (%d threads)...\n", THREADS);
    pthread_t threads[THREADS];
    size_t offsets[THREADS];
    for (int i = 0; i < THREADS; i++) {
        size_t base = (rand() % (REGION_SIZE / THREADS - 2 * HAMMER_SPAN)) + i * (REGION_SIZE / THREADS);
        offsets[i] = base;
        pthread_create(&threads[i], NULL, hammer_thread, &offsets[i]);
    }

    for (int i = 0; i < THREADS; i++) {
        pthread_join(threads[i], NULL);
    }

    printf("[*] Checking for flips...\n");
    int flip_count = 0;
    for (size_t i = 0; i < REGION_SIZE; i++) {
        if (region[i] != PATTERN) {
            int delta = __builtin_popcount(region[i] ^ PATTERN);
            log_event("FLIP", i, PATTERN, region[i], delta);
            flip_count++;
        }
    }

    fclose(logfile);
    free(region);
    printf("[✓] Test complete.\n");
    printf("    → Bit flips detected: %d\n", flip_count);
    printf("    → Logs saved to 'dram_aggressive_log.csv'\n");
    return 0;
}
