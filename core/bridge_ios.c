//go:build ios && cgo

#include "bridge_ios.h"
static FlClashCallback on_result;
static FlClashCallback on_event;
static FlClashCallback on_packet;
void flclash_set_callbacks(FlClashCallback result, FlClashCallback event, FlClashCallback packet) {
    on_result = result;
    on_event = event;
    on_packet = packet;
}
void flclash_result(void *context, const unsigned char *data, int length) {
    if (on_result) on_result(context, data, length);
}
void flclash_event(const unsigned char *data, int length) {
    if (on_event) on_event(0, data, length);
}
void flclash_packet(const unsigned char *data, int length) {
    if (on_packet) on_packet(0, data, length);
}
