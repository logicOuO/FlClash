#ifndef FLCLASH_IOS_BRIDGE_H
#define FLCLASH_IOS_BRIDGE_H
#include <stdint.h>
typedef void (*FlClashCallback)(void *, const unsigned char *, int);
void flclash_set_callbacks(FlClashCallback result, FlClashCallback event, FlClashCallback packet);
void flclash_result(void *context, const unsigned char *data, int length);
void flclash_event(const unsigned char *data, int length);
void flclash_packet(const unsigned char *data, int length);
#endif
