// Read-only AppleSMC ABI, informed by exelban/Stats (MIT).
// See THIRD_PARTY_NOTICES.md. No write or fan-control commands are exposed.
#include "CSMC.h"
#include <stddef.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMLimits;
typedef struct { uint32_t size, type; uint8_t attributes; } SMInfo;
typedef struct {
    uint32_t key;
    SMVersion version;
    SMLimits limits;
    SMInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMRequest;

_Static_assert(sizeof(SMRequest) == 80, "Unexpected SMC ABI size");
_Static_assert(offsetof(SMRequest, bytes) == 48, "Unexpected SMC ABI offset");

static kern_return_t call(io_connect_t connection, SMRequest *input, SMRequest *output) {
    size_t size = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    if (result != KERN_SUCCESS) return result;
    if (size != sizeof(*output)) return kIOReturnUnderrun;
    return output->result == 0 ? KERN_SUCCESS : kIOReturnNotFound;
}

kern_return_t SMOpen(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

void SMClose(io_connect_t connection) { if (connection) IOServiceClose(connection); }

kern_return_t SMRead(io_connect_t connection, uint32_t key, SMValue *value) {
    SMRequest input = {0}, output = {0};
    input.key = key;
    input.command = 9; // Read metadata.
    kern_return_t result = call(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;
    if (output.info.size == 0 || output.info.size > 32) return kIOReturnBadArgument;
    value->size = output.info.size;
    value->type = output.info.type;
    input.info.size = output.info.size;
    input.command = 5; // Read bytes.
    memset(&output, 0, sizeof(output));
    result = call(connection, &input, &output);
    if (result == KERN_SUCCESS) memcpy(value->bytes, output.bytes, value->size);
    return result;
}

kern_return_t SMKeyAt(io_connect_t connection, uint32_t index, uint32_t *key) {
    SMRequest input = {0}, output = {0};
    input.command = 8;
    input.index = index;
    kern_return_t result = call(connection, &input, &output);
    if (result == KERN_SUCCESS) *key = output.key;
    return result;
}
