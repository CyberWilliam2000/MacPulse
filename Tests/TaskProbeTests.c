#include "../Sources/Probe.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    char data[1024] = {0}; int argc = 4; memcpy(data, &argc, sizeof(argc));
    const char values[] = "/Applications/test\0\0test\0--type=utility\0--utility-sub-type=audio.mojom.AudioService\0--secret=do-not-retain\0--type=renderer\0";
    memcpy(data + sizeof(argc), values, sizeof(values));
    TaskProbe r = pulse_task_parse(data, sizeof(argc) + sizeof(values));
    assert(r.ok && !strcmp(r.type, "utility") && !strcmp(r.service, "audio.mojom.AudioService"));
    assert(!r.renderer[0]); // The environment/trailing strings must not be scanned.
    assert(!pulse_task_parse(data, 2).ok);
    argc = -1; memcpy(data, &argc, sizeof(argc)); assert(!pulse_task_parse(data, sizeof(data)).ok);
    argc = 2; memcpy(data, &argc, sizeof(argc));
    const char bad[] = "/test\0\0test\0--type=https://private.example/token\0";
    memcpy(data + sizeof(argc), bad, sizeof(bad));
    r = pulse_task_parse(data, sizeof(argc) + sizeof(bad));
    assert(r.ok && !r.type[0]); // Restrict output to small identifiers.
    const char truncated[] = "/test\0\0test\0--type=renderer";
    memcpy(data + sizeof(argc), truncated, sizeof(truncated));
    assert(!pulse_task_parse(data, sizeof(argc) + sizeof(truncated) - 1).ok);
    puts("Task argument checks passed (whitelist, argument boundary, invalid input, truncation).");
}
