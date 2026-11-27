#include "../Sources/Probe.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static uint64_t self_cpu(void) {
    int capacity = pulse_process_capacity(), listed = 0;
    ProcessProbe *processes = calloc((size_t)capacity, sizeof(ProcessProbe));
    assert(processes);
    int count = pulse_processes(processes, capacity, &listed);
    uint64_t own = 0;
    for (int i = 0; i < count; i++) {
        if (processes[i].pid == getpid()) { own = processes[i].cpuNS; break; }
    }
    free(processes);
    assert(own > 0);
    return own;
}

int main(void) {
    uint64_t baseline = self_cpu();
    uint64_t begin = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID);
    while (clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - begin < UINT64_C(80000000)) {}
    uint64_t delta = self_cpu() - baseline;
    uint64_t reference = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - begin;
    double ratio = (double)delta / (double)reference;
    printf("Process CPU counter measured %.0f%% of the reference clock.\n", 100 * ratio);
    assert(ratio > 0.82 && ratio < 1.18);
}
