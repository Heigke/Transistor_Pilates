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
#define REGION_MB       (1024 * 1024)
#define PATTERN         0xAA
#define MAX_ROUNDS      200000000           // total hammer rounds
#define STRIDE          64
#define CANDIDATES      128                 // candidate regions
#define PHYS_ADDR_MIN   (1ULL << 30)        // skip pages < 1GB PA
#define BURST_LEN       20000               // hammer burst length
#define COOLDOWN_LEN    5000                // hammer cooldown length
#define ENTROPY_WINDOW  1000000             // rounds per entropy/flip log
#define ENTROPY_LOW     0.001
#define ENTROPY_HIGH    0.03

// Logging/entropy/flip data
typedef struct {
    double entropy;
    int flips;
} region_state_t;

uint8_t* region;
FILE* logfile;
region_state_t region_state[REGION_SIZE / REGION_MB];

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

// Per-MB entropy calculation
void update_region_entropy() {
    for (size_t offset = 0; offset < REGION_SIZE; offset += REGION_MB) {
        region_state[offset / REGION_MB].entropy =
            calculate_entropy(region + offset, REGION_MB);
    }
}

// Per-MB flip counter (run after hammering)
void count_region_flips() {
    for (size_t i = 0; i < REGION_SIZE / REGION_MB; i++)
        region_state[i].flips = 0;
    for (size_t i = 0; i < REGION_SIZE; i++) {
        if (region[i] != PATTERN)
            region_state[i / REGION_MB].flips++;
    }
}

// Adaptive hammer, slides to new region if “calm”
void adaptive_hammer() {
    size_t hammer_mb = rand() % (REGION_SIZE / REGION_MB); // random start
    size_t rounds = 0;
    int delay_us = 0;
    int burst_counter = 0, cooldown_counter = 0;

    printf("[*] Entering adaptive hammer loop (max rounds %d)...\n", MAX_ROUNDS);
    while (rounds < MAX_ROUNDS) {
        // Hammer burst (rapid fire)
        for (burst_counter = 0; burst_counter < BURST_LEN && rounds < MAX_ROUNDS; burst_counter++, rounds++) {
            size_t base = hammer_mb * REGION_MB;
            for (size_t k = 0; k < REGION_MB; k += 4096 * 2) {
                uint8_t* a = region + base + k;
                uint8_t* b = region + base + k + 4096;
                _mm_clflush(a);
                _mm_clflush(b);
                *(volatile uint8_t*)a;
                *(volatile uint8_t*)b;
            }
            if (delay_us > 0) usleep(delay_us);
        }

        // Cooldown period (neural "refractory" phase)
        for (cooldown_counter = 0; cooldown_counter < COOLDOWN_LEN && rounds < MAX_ROUNDS; cooldown_counter++, rounds++) {
            usleep(20); // pause
        }

        // Periodically sense & log entropy and flips, and adapt window
        if (rounds % ENTROPY_WINDOW < BURST_LEN + COOLDOWN_LEN) {
            update_region_entropy();
            count_region_flips();

            // Log region-wise entropy/flip state
            for (size_t mb = 0; mb < REGION_SIZE / REGION_MB; mb++) {
                fprintf(logfile, "REGION,%zu,%zu,%.5f,%d\n",
                        rounds, mb, region_state[mb].entropy, region_state[mb].flips);
            }
            fflush(logfile);

            // Check for calmness and shift hammer window if needed
            if (region_state[hammer_mb].entropy < ENTROPY_LOW &&
                region_state[hammer_mb].flips == 0) {
                // Slide to next region (or randomize)
                size_t new_mb = (hammer_mb + 1) % (REGION_SIZE / REGION_MB);
                if (new_mb == hammer_mb) new_mb = rand() % (REGION_SIZE / REGION_MB);
                hammer_mb = new_mb;
                delay_us = 0; // reset delay for new region
                printf("Switching to region %zu (entropy calm, flips=0)\n", hammer_mb);
            } else if (region_state[hammer_mb].entropy > ENTROPY_HIGH) {
                delay_us += 50; // system "pushes back" → back off
            } else if (region_state[hammer_mb].entropy < ENTROPY_LOW) {
                delay_us = (delay_us > 10) ? delay_us - 10 : 0; // "push" harder
            }
        }
    }
}

int main() {
    printf("[*] Adaptive Feedback Neuromorphic Rowhammer\n");
    srand(time(NULL));

    region = aligned_alloc(PAGE_SIZE, REGION_SIZE);
    if (!region) { perror("alloc"); return 1; }
    memset(region, PATTERN, REGION_SIZE);
    // Force DRAM mapping
    for (size_t i = 0; i < REGION_SIZE; i += PAGE_SIZE)
        region[i] = PATTERN;

    logfile = fopen("neuromorphic_rowhammer_log.csv", "w");
    if (!logfile) { perror("log open"); return 1; }
    fprintf(logfile, "event,round,region_mb,entropy,flips\n");

    adaptive_hammer();

    // Final global check for flips
    int flip_total = 0;
    for (size_t i = 0; i < REGION_SIZE; i++) {
        if (region[i] != PATTERN) {
            flip_total++;
        }
    }

    printf("[✓] Done. Bit flips: %d\n", flip_total);
    printf("    → Logs: neuromorphic_rowhammer_log.csv\n");
    fclose(logfile);
    free(region);
    return 0;
}
