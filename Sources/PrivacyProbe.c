#include "Probe.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreMediaIO/CMIOHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>

static OSStatus audioGet(AudioObjectID o, AudioObjectPropertySelector s,
                         AudioObjectPropertyScope scope, void *v, UInt32 *n) {
    AudioObjectPropertyAddress a = {s, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(o, &a, 0, NULL, n, v);
}
static int audioString(AudioObjectID o, AudioObjectPropertySelector prop, char *out, size_t cap) {
    CFStringRef s = NULL; UInt32 n = sizeof(s);
    OSStatus err = audioGet(o, prop, kAudioObjectPropertyScopeGlobal, &s, &n);
    if (err || !s) return 0;
    int ok = CFStringGetCString(s, out, cap, kCFStringEncodingUTF8);
    CFRelease(s); return ok;
}
static AudioObjectID *audioList(AudioObjectID o, AudioObjectPropertySelector prop,
                                 AudioObjectPropertyScope scope, UInt32 *count, int *ok) {
    AudioObjectPropertyAddress a = {prop, scope, kAudioObjectPropertyElementMain};
    UInt32 n = 0; *count = 0; *ok = 0;
    if (AudioObjectGetPropertyDataSize(o, &a, 0, NULL, &n) || n > 1024 * 1024) return NULL;
    if (!n) { *ok = 1; return NULL; }
    AudioObjectID *items = calloc(1, n);
    if (!items) return NULL;
    if (AudioObjectGetPropertyData(o, &a, 0, NULL, &n, items)) { free(items); return NULL; }
    *count = n / sizeof(*items); *ok = 1; return items;
}
PrivacyProbe pulse_privacy(void) {
    PrivacyProbe r = {0}; UInt32 n = sizeof(AudioObjectID); AudioObjectID def = 0;
    audioGet(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice,
             kAudioObjectPropertyScopeGlobal, &def, &n);
    if (def) audioString(def, kAudioObjectPropertyName, r.defaultInput, sizeof(r.defaultInput));
    UInt32 count = 0; int ok = 0;
    AudioObjectID *processes = audioList(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList,
                                        kAudioObjectPropertyScopeGlobal, &count, &ok);
    // A restricted helper can return an empty HAL with success. Do not call it idle.
    r.audioOK = ok && (count > 0 || def != 0);
    for (UInt32 i = 0; i < count; i++) {
        UInt32 active = 0; n = sizeof(active);
        if (audioGet(processes[i], kAudioProcessPropertyIsRunningInput,
                     kAudioObjectPropertyScopeGlobal, &active, &n)) { r.audioPartial = 1; continue; }
        if (!active) continue;
        pid_t pid = 0; n = sizeof(pid);
        if (audioGet(processes[i], kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid, &n)) {
            r.audioPartial = 1; continue;
        }
        char bundle[256] = {0}; audioString(processes[i], kAudioProcessPropertyBundleID, bundle, sizeof(bundle));
        UInt32 dc = 0; int dok = 0;
        AudioObjectID *devices = audioList(processes[i], kAudioProcessPropertyDevices,
                                           kAudioObjectPropertyScopeInput, &dc, &dok);
        if (!dok) r.audioPartial = 1;
        // Preserve an active process even when its device cannot be resolved.
        UInt32 rows = dc ? dc : 1;
        for (UInt32 k = 0; k < rows; k++) {
            if (r.microphoneCount >= 128) { r.audioPartial = 1; break; }
            MicrophoneUse *u = &r.microphones[r.microphoneCount++];
            u->pid = pid; memcpy(u->bundle, bundle, sizeof(bundle));
            struct rusage_info_v2 usage = {0};
            if (!proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage)) u->birth = usage.ri_proc_start_abstime;
            struct proc_bsdinfo info = {0};
            if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info))
                u->start = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
            if (dc) {
                u->deviceID = devices[k];
                audioString(devices[k], kAudioObjectPropertyName, u->device, sizeof(u->device));
            }
        }
        free(devices);
    }
    free(processes);
    CMIOObjectPropertyAddress a = {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal,
                                   kCMIOObjectPropertyElementMain};
    n = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &a, 0, NULL, &n) || n > 1024 * 1024) return r;
    if (!n) { r.cameraOK = 1; return r; }
    CMIOObjectID *devices = calloc(1, n);
    if (!devices) return r;
    if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &a, 0, NULL, n, &n, devices)) {
        free(devices); return r;
    }
    count = n / sizeof(*devices); r.cameraOK = 1;
    for (UInt32 i = 0; i < count; i++) {
        if (r.cameraCount >= 32) { r.cameraPartial = 1; break; }
        CameraState *c = &r.cameras[r.cameraCount++]; c->deviceID = devices[i]; c->running = -1;
        CFStringRef s = NULL; UInt32 z = sizeof(s); a.mSelector = kCMIOObjectPropertyName;
        if (!CMIOObjectGetPropertyData(devices[i], &a, 0, NULL, z, &z, &s) && s) {
            CFStringGetCString(s, c->name, sizeof(c->name), kCFStringEncodingUTF8); CFRelease(s);
        }
        UInt32 running = 0; z = sizeof(running); a.mSelector = kCMIODevicePropertyDeviceIsRunningSomewhere;
        if (!CMIOObjectGetPropertyData(devices[i], &a, 0, NULL, z, &z, &running)) c->running = running ? 1 : 0;
        else r.cameraPartial = 1;
    }
    free(devices); return r;
}
