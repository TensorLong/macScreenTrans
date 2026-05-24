#include "CMultitouchSupport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, void *data, int contactCount, double timestamp, int frame);
typedef CFMutableArrayRef (*MTDeviceCreateListFunction)(void);
typedef void (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef void (*MTUnregisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef void (*MTDeviceStartFunction)(MTDeviceRef device, int flags);
typedef void (*MTDeviceStopFunction)(MTDeviceRef device);

// MultitouchSupport private per-finger payload (reverse-engineered, stable across
// macOS versions used by OpenMultitouchSupport, mac-gesture, Hammerspoon, etc.).
// We only need normalizedVector.{x,y}; the rest of the struct exists to keep the
// memory layout correct when indexing into the array MultitouchSupport hands us.
typedef struct {
    float x;
    float y;
    float vx;
    float vy;
} MSMTPoint;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int finger;
    int hand;
    MSMTPoint normalizedVector;
    MSMTPoint absoluteVector;
    int unknown1[2];
    float size;
    int unknown2;
    float angle;
    float majorAxis;
    float minorAxis;
    MSMTPoint mm;
    int unknown3[2];
    float zDensity;
} MSMTTouch;

static void *gFramework = NULL;
static CFMutableArrayRef gDevices = NULL;
static MSTouchFrameCallback gCallback = NULL;
static void *gContext = NULL;
static MTUnregisterContactFrameCallbackFunction gUnregisterCallback = NULL;
static MTDeviceStopFunction gDeviceStop = NULL;

static void writeError(char *buffer, int length, const char *message) {
    if (buffer == NULL || length <= 0) {
        return;
    }
    snprintf(buffer, (size_t)length, "%s", message);
}

static int touchFrameCallback(MTDeviceRef device, void *data, int contactCount, double timestamp, int frame) {
    (void)device;

    float centroidX = 0.0f;
    float centroidY = 0.0f;
    if (contactCount > 0 && data != NULL) {
        const MSMTTouch *touches = (const MSMTTouch *)data;
        float sumX = 0.0f;
        float sumY = 0.0f;
        for (int i = 0; i < contactCount; i++) {
            sumX += touches[i].normalizedVector.x;
            sumY += touches[i].normalizedVector.y;
        }
        centroidX = sumX / (float)contactCount;
        centroidY = sumY / (float)contactCount;
    }

    if (gCallback != NULL) {
        gCallback(contactCount, timestamp, frame, centroidX, centroidY, gContext);
    }
    return 0;
}

bool MSTrackpadStart(MSTouchFrameCallback callback, void *context, char *errorBuffer, int errorBufferLength) {
    if (gDevices != NULL) {
        writeError(errorBuffer, errorBufferLength, "Trackpad monitor already running");
        return true;
    }

    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
    gFramework = dlopen(path, RTLD_LAZY);
    if (gFramework == NULL) {
        const char *error = dlerror();
        writeError(errorBuffer, errorBufferLength, error != NULL ? error : "Unable to load MultitouchSupport");
        return false;
    }

    MTDeviceCreateListFunction createList = (MTDeviceCreateListFunction)dlsym(gFramework, "MTDeviceCreateList");
    MTRegisterContactFrameCallbackFunction registerCallback =
        (MTRegisterContactFrameCallbackFunction)dlsym(gFramework, "MTRegisterContactFrameCallback");
    gUnregisterCallback =
        (MTUnregisterContactFrameCallbackFunction)dlsym(gFramework, "MTUnregisterContactFrameCallback");
    MTDeviceStartFunction deviceStart = (MTDeviceStartFunction)dlsym(gFramework, "MTDeviceStart");
    gDeviceStop = (MTDeviceStopFunction)dlsym(gFramework, "MTDeviceStop");

    if (createList == NULL || registerCallback == NULL || deviceStart == NULL) {
        writeError(errorBuffer, errorBufferLength, "MultitouchSupport symbols are unavailable");
        dlclose(gFramework);
        gFramework = NULL;
        return false;
    }

    gDevices = createList();
    if (gDevices == NULL || CFArrayGetCount(gDevices) == 0) {
        writeError(errorBuffer, errorBufferLength, "No multitouch trackpad devices found");
        if (gDevices != NULL) {
            CFRelease(gDevices);
            gDevices = NULL;
        }
        dlclose(gFramework);
        gFramework = NULL;
        return false;
    }

    gCallback = callback;
    gContext = context;

    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex index = 0; index < count; index++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, index);
        registerCallback(device, touchFrameCallback);
        deviceStart(device, 0);
    }

    writeError(errorBuffer, errorBufferLength, "");
    return true;
}

void MSTrackpadStop(void) {
    if (gDevices != NULL) {
        CFIndex count = CFArrayGetCount(gDevices);
        for (CFIndex index = 0; index < count; index++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, index);
            if (gUnregisterCallback != NULL) {
                gUnregisterCallback(device, touchFrameCallback);
            }
            if (gDeviceStop != NULL) {
                gDeviceStop(device);
            }
        }
        CFRelease(gDevices);
        gDevices = NULL;
    }

    gCallback = NULL;
    gContext = NULL;
    gUnregisterCallback = NULL;
    gDeviceStop = NULL;

    if (gFramework != NULL) {
        dlclose(gFramework);
        gFramework = NULL;
    }
}
