#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <x86intrin.h>
#include <pthread.h>
#include <sched.h>
#include <math.h>
#include <sys/mman.h>

#define REGION_SIZE     (64 * 1024 * 1024) // 64MB
#define PAGE_SIZE       4096
#define PATTERN         0xAA
#define HAMMER_ROUNDS   500000000  // Longer duration for real effect
#define THREADS         4
#define HAMMER_STRIDE   64
#define CANDIDATES      32
#define PHYS_ADDR_MIN   (1ULL << 30) // skip pages < 1GB PA

uint8_t* region;
FILE* logfile;

uint64_t virt_to_phys(void* addr) {
    uint64_t value;
    int pagemap = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap < 0) return 0;

    size_t offset = ((uintptr_t)addr / PAGE_SIZE) * sizeof(uint64_t);
    if (lseek(pagemap, offset, SEEK_SET) == -1) return 0;

    if (read(pagemap, &value, sizeof(uint64_t)) != sizeof(uint64_t)) return 0;

    close(pagemap);
    if (!(value & (1ULL << 63))) return 0; // not present
    return (value & ((1ULL << 55) - 1)) * PAGE_SIZE + ((uintptr_t)addr % PAGE_SIZE);
}

uint64_t measure_access_ns(uint8_t* ptr) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC_RAW, &start);
    *(volatile uint8_t*)ptr;
    clock_gettime(CLOCK_MONOTONIC_RAW, &end);
    return (end.tv_sec * 1000000000ULL + end.tv_nsec) -
           (start.tv_sec * 1000000000ULL + start.tv_nsec);
}

void log_event(const char* type, size_t offset, uint8_t expected, uint8_t actual, int delta_bits) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(logfile, "%s,%ld.%09ld,0x%zx,0x%02x,0x%02x,%d\n",
            type, ts.tv_sec, ts.tv_nsec, offset, expected, actual, delta_bits);
    fflush(logfile);
}

typedef struct {
    uint8_t* addr;
    uint64_t latency;
    uint64_t phys_addr;
} target_t;

int compare_latency(const void* a, const void* b) {
    return ((target_t*)b)->latency - ((target_t*)a)->latency;
}

void* hammer_thread(void* arg) {
    uint8_t** targets = (uint8_t**)arg;
    for (int i = 0; i < HAMMER_ROUNDS; i++) {
        for (int j = 0; j < 2; j++) {
            _mm_clflush(targets[j]);
            *(volatile uint8_t*)targets[j];
        }
        _mm_mfence();
    }
    return NULL;
}

int main(int argc, char** argv) {
    printf("[*] Smarter DRAM Neuromorphic Hammer\n");
    srand(time(NULL));

    region = aligned_alloc(PAGE_SIZE, REGION_SIZE);
    if (!region) {
        perror("alloc");
        return 1;
    }

    memset(region, PATTERN, REGION_SIZE);

    // Force commit pages to physical memory
    for (size_t i = 0; i < REGION_SIZE; i += PAGE_SIZE) {
        region[i] = PATTERN;
        asm volatile("" ::: "memory");
    }

    logfile = fopen("dram_smart_log.csv", "w");
    if (!logfile) {
        perror("log open");
        return 1;
    }
    fprintf(logfile, "event,timestamp,offset,expected,actual,delta_bits\n");

    // Profile memory latency for hammer candidates
    target_t candidates[CANDIDATES];
    int found = 0;
    while (found < CANDIDATES) {
        uint8_t* ptr = region + (rand() % (REGION_SIZE - PAGE_SIZE));
        uint64_t pa = virt_to_phys(ptr);
        if (pa == 0 || pa < PHYS_ADDR_MIN) continue;

        uint64_t total = 0;
        for (int j = 0; j < 10; j++) {
            _mm_clflush(ptr);
            _mm_mfence();
            total += measure_access_ns(ptr);
        }
        candidates[found].addr = ptr;
        candidates[found].latency = total / 10;
        candidates[found].phys_addr = pa;
        found++;
    }

    qsort(candidates, CANDIDATES, sizeof(target_t), compare_latency);

    printf("[*] Hammering best latency pair:\n");
    for (int i = 0; i < 2; i++) {
        printf("    [%d] VA=%p, PA=0x%lx, Latency=~%lu ns\n",
               i, candidates[i].addr, candidates[i].phys_addr, candidates[i].latency);
    }

    uint8_t* pair[2] = { candidates[0].addr, candidates[1].addr };
    pthread_t t;
    pthread_create(&t, NULL, hammer_thread, pair);
    pthread_join(t, NULL);

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
    printf("    → Logs saved to 'dram_smart_log.csv'\n");

    return 0;
}
