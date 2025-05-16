#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <x86intrin.h>
#include <math.h>
#include <sys/mman.h>

#define REGION_SIZE     (64 * 1024 * 1024)  // 64MB
#define PAGE_SIZE       4096
#define PATTERN         0xAA
#define BURST_LEN       100000
#define COOLDOWN_US     1000
#define PHYS_ADDR_MIN   (1ULL << 30)        // skip pages < 1GB PA

typedef struct {
    size_t idx_aggr1, idx_victim, idx_aggr2;
    uint64_t flips;
} hammer_result_t;

uint8_t* region;
uint64_t* phys_addrs;

uint64_t virt_to_phys(void* addr) {
    uint64_t value;
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    size_t offset = ((uintptr_t)addr / PAGE_SIZE) * sizeof(uint64_t);
    if (lseek(fd, offset, SEEK_SET) == -1) return 0;
    if (read(fd, &value, sizeof(uint64_t)) != sizeof(uint64_t)) return 0;
    close(fd);
    if (!(value & (1ULL << 63))) return 0;
    return (value & ((1ULL << 55) - 1)) * PAGE_SIZE + ((uintptr_t)addr % PAGE_SIZE);
}

void fill_pattern(uint8_t* mem, size_t len, uint8_t val) {
    memset(mem, val, len);
}

uint64_t count_flips(uint8_t* mem, size_t len, uint8_t pattern) {
    uint64_t flips = 0;
    for (size_t i = 0; i < len; i++) {
        if (mem[i] != pattern)
            flips++;
    }
    return flips;
}

void hammer_pair(uint8_t* aggr1, uint8_t* aggr2, size_t burst_len) {
    for (size_t i = 0; i < burst_len; i++) {
        _mm_clflush(aggr1);
        _mm_clflush(aggr2);
        *(volatile uint8_t*)aggr1;
        *(volatile uint8_t*)aggr2;
        _mm_mfence();
    }
}

int main() {
    printf("[*] Smart Physical Rowhammer - Neuromorphic Metrics\n");
    srand(time(NULL));

    size_t num_pages = REGION_SIZE / PAGE_SIZE;
    region = aligned_alloc(PAGE_SIZE, REGION_SIZE);
    if (!region) { perror("alloc"); return 1; }
    fill_pattern(region, REGION_SIZE, PATTERN);
    // Touch every page to back it with DRAM
    for (size_t i = 0; i < REGION_SIZE; i += PAGE_SIZE)
        region[i] = PATTERN;

    // Map all physical addresses
    phys_addrs = malloc(num_pages * sizeof(uint64_t));
    if (!phys_addrs) { perror("phys_addrs"); free(region); return 1; }
    for (size_t i = 0; i < num_pages; i++)
        phys_addrs[i] = virt_to_phys(region + i * PAGE_SIZE);

    // Find all double-sided candidate triplets
    size_t max_candidates = num_pages - 2;
    hammer_result_t* results = calloc(max_candidates, sizeof(hammer_result_t));
    size_t num_candidates = 0;
    for (size_t i = 0; i < num_pages - 2; i++) {
        if (phys_addrs[i] < PHYS_ADDR_MIN || phys_addrs[i+1] < PHYS_ADDR_MIN || phys_addrs[i+2] < PHYS_ADDR_MIN)
            continue;
        if ((phys_addrs[i+1] == phys_addrs[i] + PAGE_SIZE) && (phys_addrs[i+2] == phys_addrs[i+1] + PAGE_SIZE)) {
            // i = aggr1, i+1 = victim, i+2 = aggr2
            results[num_candidates].idx_aggr1 = i;
            results[num_candidates].idx_victim = i+1;
            results[num_candidates].idx_aggr2 = i+2;
            num_candidates++;
        }
    }
    printf("[*] Found %zu candidate physically-contiguous triplets\n", num_candidates);
    if (num_candidates == 0) {
        printf("[!] No candidates found. Try on bare metal with large pages.\n");
        free(region); free(phys_addrs); free(results); return 1;
    }

    // Log file for all flips found
    FILE* flog = fopen("rowhammer_results.csv", "w");
    fprintf(flog, "candidate,aggr1_pa,victim_pa,aggr2_pa,flips\n");

    // Hammer all candidates
    uint64_t total_flips = 0, best_flips = 0;
    size_t best_candidate = 0;
    for (size_t c = 0; c < num_candidates; c++) {
        uint8_t* aggr1 = region + results[c].idx_aggr1 * PAGE_SIZE;
        uint8_t* victim = region + results[c].idx_victim * PAGE_SIZE;
        uint8_t* aggr2 = region + results[c].idx_aggr2 * PAGE_SIZE;

        // Reset the window
        fill_pattern(victim, PAGE_SIZE, PATTERN);
        fill_pattern(aggr1, PAGE_SIZE, PATTERN);
        fill_pattern(aggr2, PAGE_SIZE, PATTERN);

        hammer_pair(aggr1, aggr2, BURST_LEN);
        usleep(COOLDOWN_US);

        results[c].flips = count_flips(victim, PAGE_SIZE, PATTERN);
        if (results[c].flips > best_flips) {
            best_flips = results[c].flips;
            best_candidate = c;
        }
        total_flips += results[c].flips;
        fprintf(flog, "%zu,0x%lx,0x%lx,0x%lx,%lu\n",
            c,
            phys_addrs[results[c].idx_aggr1],
            phys_addrs[results[c].idx_victim],
            phys_addrs[results[c].idx_aggr2],
            results[c].flips
        );

        if (c % 10 == 0 || results[c].flips > 0)
            printf("Candidate %zu/%zu: flips=%lu\n", c, num_candidates, results[c].flips);
    }
    fclose(flog);

    printf("[✓] Hammering complete.\n");
    printf("    → Total flips: %lu\n", total_flips);
    if (best_flips)
        printf("    → Best candidate: %zu (flips=%lu)\n", best_candidate, best_flips);
    else
        printf("    → No flips detected. Try increasing BURST_LEN or test on older hardware/disable ECC/TRR.\n");
    printf("    → All results in rowhammer_results.csv\n");

    free(region); free(phys_addrs); free(results);
    return 0;
}
