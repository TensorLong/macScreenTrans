#ifndef CMultitouchSupport_h
#define CMultitouchSupport_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MSTouchFrameCallback)(int contactCount, double timestamp, int frame,
                                     float centroidX, float centroidY, void *context);

bool MSTrackpadStart(MSTouchFrameCallback callback, void *context, char *errorBuffer, int errorBufferLength);
void MSTrackpadStop(void);

// Computes the centroid of all touches whose state indicates a firmly-down
// finger (state 3 = MakeTouch, state 4 = Touching). Returns the count of
// firm touches via *firmCount and writes the centroid to *outX/*outY. When
// no firm touches exist, *outX and *outY are set to 0 and *firmCount to 0.
// Exposed for unit-test coverage of the per-touch buffer striding.
void MSComputeCentroid(const void *touchesBuffer, int contactCount,
                       int *firmCount, float *outX, float *outY);

#ifdef __cplusplus
}
#endif

#endif
