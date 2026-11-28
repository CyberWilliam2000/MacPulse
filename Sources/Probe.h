#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint32_t ticks[4];
    int cpuOK, vmOK, pressure, diskOK;
    uint64_t swapUsed, swapIn, swapOut, compressed;
    int swapOK;
    uint64_t diskRead, diskWrite, diskOps, diskTime, diskIdentity;
    uint64_t freeBytes, totalBytes;
} SystemProbe;

typedef struct {
    int pid, parent;
    uint64_t start, cpuNS, memory, read, write;
} ProcessProbe;

typedef struct {
    double celsius;
    char name[96];
    int count;
} TemperatureProbe;

SystemProbe pulse_system(void);
int pulse_process_capacity(void);
int pulse_processes(ProcessProbe *out, int capacity, int *listed);
int pulse_process_path(int pid, char *out, int length);
uint64_t pulse_process_birth(int pid);
TemperatureProbe pulse_temperature(void);

typedef struct {
    int pid;
    uint64_t start;
    uint64_t birth;
    char bundle[256], device[256];
    uint32_t deviceID;
} MicrophoneUse;
typedef struct {
    uint32_t deviceID;
    int running; // -1 unavailable
    char name[256];
} CameraState;
typedef struct {
    int audioOK, cameraOK, audioPartial, cameraPartial;
    int microphoneCount, cameraCount;
    MicrophoneUse microphones[128];
    CameraState cameras[32];
    char defaultInput[256];
} PrivacyProbe;
PrivacyProbe pulse_privacy(void);

typedef struct {
    int ok;
    char type[48], service[128], renderer[32];
} TaskProbe;
TaskProbe pulse_task(int pid);
TaskProbe pulse_task_parse(const void *data, size_t length);
