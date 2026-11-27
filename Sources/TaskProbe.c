#include "Probe.h"
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static void copy_identifier(char *out, size_t capacity, const char *value, size_t length) {
    if (!length || length >= capacity) return;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = value[i];
        if (!(isalnum(c) || c == '.' || c == '_' || c == '-')) return;
    }
    memcpy(out, value, length); out[length] = 0;
}
TaskProbe pulse_task_parse(const void *data, size_t length) {
    TaskProbe result = {0};
    if (length < sizeof(int)) return result;
    int argc = 0; memcpy(&argc, data, sizeof(argc));
    if (argc <= 0 || argc > 65536) return result;
    const char *cursor = (const char *)data + sizeof(int), *end = (const char *)data + length;
    const char *zero = memchr(cursor, 0, end - cursor); // executable, followed by NUL padding
    if (!zero) return result;
    cursor = zero + 1;
    while (cursor < end && *cursor == 0) cursor++;
    for (int i = 0; i < argc; i++) {
        zero = memchr(cursor, 0, end - cursor);
        if (!zero) return (TaskProbe){0};
        size_t n = zero - cursor;
        const char *prefixes[] = {"--type=", "--utility-sub-type=", "--renderer-client-id="};
        char *outputs[] = {result.type, result.service, result.renderer};
        size_t caps[] = {sizeof(result.type), sizeof(result.service), sizeof(result.renderer)};
        for (int k = 0; k < 3; k++) {
            size_t p = strlen(prefixes[k]);
            if (n > p && !memcmp(cursor, prefixes[k], p)) copy_identifier(outputs[k], caps[k], cursor + p, n - p);
        }
        cursor = zero + 1;
    }
    result.ok = 1; return result;
}
TaskProbe pulse_task(int pid) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid}; size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) || length < sizeof(int) || length > 2 * 1024 * 1024) return (TaskProbe){0};
    size_t capacity = length;
    void *data = malloc(capacity); if (!data) return (TaskProbe){0};
    TaskProbe r = {0};
    if (!sysctl(mib, 3, data, &length, NULL, 0) && length <= capacity) r = pulse_task_parse(data, length);
    memset(data, 0, capacity); free(data); return r;
}
