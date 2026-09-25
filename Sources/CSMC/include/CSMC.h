#ifndef STATUS_MONITOR_SMC_H
#define STATUS_MONITOR_SMC_H
#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct {
    uint32_t size;
    uint32_t type;
    uint8_t bytes[32];
} SMValue;

kern_return_t SMOpen(io_connect_t *connection);
void SMClose(io_connect_t connection);
kern_return_t SMRead(io_connect_t connection, uint32_t key, SMValue *value);
kern_return_t SMKeyAt(io_connect_t connection, uint32_t index, uint32_t *key);
#endif
