#ifndef CMultitouchSupport_h
#define CMultitouchSupport_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// deviceID is the MTDeviceRef pointer value, stable for the device's
// lifetime. Frames from different devices (built-in trackpad, external
// Magic Trackpad) MUST be tracked separately — interleaving them into one
// gesture detector lets a hand resting on one device poison taps on the
// other.
typedef void (*MSTouchFrameCallback)(uint64_t deviceID, int contactCount, double timestamp, int frame,
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
