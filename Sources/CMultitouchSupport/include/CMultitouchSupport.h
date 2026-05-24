#ifndef CMultitouchSupport_h
#define CMultitouchSupport_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MSTouchFrameCallback)(int contactCount, double timestamp, int frame, void *context);

bool MSTrackpadStart(MSTouchFrameCallback callback, void *context, char *errorBuffer, int errorBufferLength);
void MSTrackpadStop(void);

#ifdef __cplusplus
}
#endif

#endif
