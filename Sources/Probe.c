#include "Probe.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>

static uint64_t statistic(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    int64_t n = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberSInt64Type, &n);
    }
    return n > 0 ? (uint64_t)n : 0;
}

SystemProbe pulse_system(void) {
    SystemProbe out = {0};
    mach_port_t host = mach_host_self();
    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) == KERN_SUCCESS) {
        out.cpuOK = 1;
        for (int i = 0; i < CPU_STATE_MAX; ++i) out.ticks[i] = cpu.cpu_ticks[i];
    }
    vm_statistics64_data_t vm = {0};
    count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        uint64_t p = (uint64_t)getpagesize();
        out.vmOK = 1;
        out.swapIn = vm.swapins * p;
        out.swapOut = vm.swapouts * p;
        out.compressed = vm.compressor_page_count * p;
    }
    mach_port_deallocate(mach_task_self(), host);

    size_t len = sizeof(out.pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &out.pressure, &len, NULL, 0) != 0) {
        out.pressure = 0;
    }
    struct xsw_usage swap = {0};
    len = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &len, NULL, 0) == 0 && len == sizeof(swap)) {
        out.swapOK = 1;
        out.swapUsed = swap.xsu_used;
    }
    struct statfs fs = {0};
    if (statfs("/System/Volumes/Data", &fs) == 0 || statfs("/", &fs) == 0) {
        out.freeBytes = (uint64_t)fs.f_bavail * fs.f_bsize;
        out.totalBytes = (uint64_t)fs.f_blocks * fs.f_bsize;
    }

    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS) {
        io_service_t service;
        while ((service = IOIteratorNext(it))) {
            CFTypeRef stats = IORegistryEntryCreateCFProperty(service, CFSTR("Statistics"), kCFAllocatorDefault, 0);
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                uint64_t id = 0;
                IORegistryEntryGetRegistryEntryID(service, &id);
                out.diskIdentity ^= id * UINT64_C(11400714819323198485);
                out.diskOK = 1;
                out.diskRead += statistic(stats, CFSTR("Bytes (Read)"));
                out.diskWrite += statistic(stats, CFSTR("Bytes (Write)"));
                out.diskOps += statistic(stats, CFSTR("Operations (Read)")) + statistic(stats, CFSTR("Operations (Write)"));
                out.diskTime += statistic(stats, CFSTR("Total Time (Read)")) + statistic(stats, CFSTR("Total Time (Write)"));
            }
            if (stats) CFRelease(stats);
            IOObjectRelease(service);
        }
        IOObjectRelease(it);
    }
    return out;
}

int pulse_process_capacity(void) {
    int n = proc_listallpids(NULL, 0);
    return n > 0 ? n + 128 : 512;
}

int pulse_processes(ProcessProbe *out, int capacity, int *listed) {
    *listed = 0;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return 0;
    int n = proc_listallpids(pids, (int)(sizeof(pid_t)*capacity));
    *listed = n > 0 ? n : 0;
    int written = 0;
    mach_timebase_info_data_t timebase = {0};
    mach_timebase_info(&timebase);
    for (int i = 0; i < n && i < capacity; ++i) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct rusage_info_v4 r = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&r) != 0) continue;
        struct proc_bsdinfo bsd = {0};
        int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
        out[written++] = (ProcessProbe){
            .pid = pid, .parent = size == sizeof(bsd) ? (int)bsd.pbi_ppid : 0,
            .start = r.ri_proc_start_abstime,
            // rusage CPU counters are Mach ticks, not nanoseconds on Apple Silicon.
            .cpuNS = timebase.denom ? (uint64_t)(((__uint128_t)r.ri_user_time + r.ri_system_time)
                                                * timebase.numer / timebase.denom) : 0,
            .memory = r.ri_phys_footprint, .read = r.ri_diskio_bytesread, .write = r.ri_diskio_byteswritten
        };
    }
    free(pids);
    return written;
}

int pulse_process_path(int pid, char *out, int length) {
    if (proc_pidpath(pid, out, (uint32_t)length) > 0) return 1;
    return proc_name(pid, out, (uint32_t)length) > 0;
}

// Optional read-only API. Resolve dynamically so a future macOS can still run without it.
TemperatureProbe pulse_temperature(void) {
    TemperatureProbe out = { .celsius = NAN };
    typedef CFTypeRef (*Create)(CFAllocatorRef);
    typedef void (*Match)(CFTypeRef, CFDictionaryRef);
    typedef CFArrayRef (*Services)(CFTypeRef);
    typedef CFTypeRef (*Property)(CFTypeRef, CFStringRef);
    typedef CFTypeRef (*Event)(CFTypeRef, int32_t, int32_t, uint64_t);
    typedef double (*Value)(CFTypeRef, int32_t);
    static Create create;
    static Match match;
    static Services services;
    static Property property;
    static Event event;
    static Value value;
    static CFTypeRef client;
    static int initialized;

    if (!initialized) {
        initialized = 1;
        create = (Create)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        match = (Match)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
        services = (Services)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
        property = (Property)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
        event = (Event)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
        value = (Value)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    }
    if (!create || !match || !services || !property || !event || !value) return out;
    if (!client) {
        client = create(kCFAllocatorDefault);
        if (!client) return out;
        int page = 0xff00, usage = 5;
        CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberIntType, &page);
        CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberIntType, &usage);
        const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
        const void *values[] = {pageNumber, usageNumber};
        CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        match(client, dict);
        CFRelease(dict);
        CFRelease(pageNumber);
        CFRelease(usageNumber);
    }
    CFArrayRef found = services(client);
    if (!found) return out;
    for (CFIndex i = 0; i < CFArrayGetCount(found); ++i) {
        CFTypeRef service = CFArrayGetValueAtIndex(found, i);
        CFTypeRef product = property(service, CFSTR("Product"));
        if (!product) continue;
        if (CFGetTypeID(product) == CFStringGetTypeID() &&
            (CFStringHasPrefix(product, CFSTR("PMU tdie")) || CFStringHasPrefix(product, CFSTR("PMU2 tdie")))) {
            const int32_t type = 15; // kIOHIDEventTypeTemperature
            CFTypeRef reading = event(service, type, 0, 0);
            if (reading) {
                double c = value(reading, type << 16);
                if (isfinite(c) && c > 0 && c < 150) {
                    out.count++;
                    if (!isfinite(out.celsius) || c > out.celsius) {
                        out.celsius = c;
                        CFStringGetCString(product, out.name, sizeof(out.name), kCFStringEncodingUTF8);
                    }
                }
                CFRelease(reading);
            }
        }
        CFRelease(product);
    }
    CFRelease(found);
    return out;
}
