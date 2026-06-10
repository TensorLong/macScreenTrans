#include "CMultitouchSupport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, void *data, int contactCount, double timestamp, int frame);
typedef CFMutableArrayRef (*MTDeviceCreateListFunction)(void);
typedef void (*MTRegisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef void (*MTUnregisterContactFrameCallbackFunction)(MTDeviceRef device, MTContactCallbackFunction callback);
typedef void (*MTDeviceStartFunction)(MTDeviceRef device, int flags);
typedef void (*MTDeviceStopFunction)(MTDeviceRef device);
typedef OSStatus (*MTDeviceGetFamilyIDFunction)(MTDeviceRef device, int *familyID);

// Canonical MTTouch layout (96 bytes) as reverse-engineered by:
//   - mkalten/twongseng
//   - ofxTouchPad
//   - asmagill/Hammerspoon
//   - KSroido
//   - rmhsilva
// All five independent sources agree on this layout. v0.2.1 shipped with a
// 120-byte struct, so touches[i].normalizedVector for i >= 1 read garbage
// from the canonical touches[i].angle / majorAxis bytes — the centroid
// drifted wildly and every 3-finger tap was rejected.
typedef struct {
    float x;
    float y;
} MSMTPointXY;

typedef struct {
    MSMTPointXY position;
    MSMTPointXY velocity;
} MSMTVector;

typedef struct {
    int32_t  frame;          // offset 0
    double   timestamp;      // offset 8 (with 4-byte pad)
    int32_t  pathIndex;      // offset 16
    int32_t  state;          // offset 20  (1=MakeTouch, 4=Touching, 5=BreakTouch, etc.)
    int32_t  fingerID;       // offset 24
    int32_t  handID;         // offset 28
    MSMTVector normalizedVector;  // offset 32 (16 bytes: pos.x, pos.y, vel.x, vel.y)
    float    zTotal;         // offset 48
    int32_t  field9;         // offset 52
    float    angle;          // offset 56
    float    majorAxis;      // offset 60
    float    minorAxis;      // offset 64
    MSMTVector absoluteVector;    // offset 68 (mm)
    int32_t  field14;        // offset 84
    int32_t  field15;        // offset 88
    float    zDensity;       // offset 92
} MSMTTouch;  // sizeof = 96

_Static_assert(sizeof(MSMTTouch) == 96, "MSMTTouch layout drifted from canonical MTTouch");
_Static_assert(__builtin_offsetof(MSMTTouch, normalizedVector) == 32, "normalizedVector must live at offset 32");

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

void MSComputeCentroid(const void *touchesBuffer, int contactCount,
                       int *firmCount, float *outX, float *outY) {
    const MSMTTouch *touches = (const MSMTTouch *)touchesBuffer;
    int firm = 0;
    float sumX = 0.0f, sumY = 0.0f;
    for (int i = 0; i < contactCount; i++) {
        int state = touches[i].state;
        if (state == 3 || state == 4) {
            sumX += touches[i].normalizedVector.position.x;
            sumY += touches[i].normalizedVector.position.y;
            firm++;
        }
    }
    if (firm > 0) {
        *outX = sumX / (float)firm;
        *outY = sumY / (float)firm;
    } else {
        *outX = 0.0f;
        *outY = 0.0f;
    }
    *firmCount = firm;
}

static int touchFrameCallback(MTDeviceRef device, void *data, int contactCount, double timestamp, int frame) {
    int firm = 0;
    float cx = 0.0f, cy = 0.0f;
    if (data && contactCount > 0) {
        MSComputeCentroid(data, contactCount, &firm, &cx, &cy);
    }
    if (gCallback != NULL) {
        gCallback((uint64_t)(uintptr_t)device, firm, timestamp, frame, cx, cy, gContext);
    }
    return 0;
}

// Magic Mouse multitouch family IDs (1st/2nd generation). The mouse's top
// shell is a raw multitouch surface that streams resting-hand contacts with
// no palm rejection at this layer; feeding those frames into tap detection
// poisons the gesture for anyone pointing with the mouse. Filtering is
// best-effort (the symbol is private and may vanish) — the per-device
// detector split on the Swift side is the structural defense.
static bool isMagicMouseFamily(int familyID) {
    return familyID == 112 || familyID == 113;
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

    MTDeviceGetFamilyIDFunction getFamilyID =
        (MTDeviceGetFamilyIDFunction)dlsym(gFramework, "MTDeviceGetFamilyID");

    CFIndex count = CFArrayGetCount(gDevices);
    CFIndex started = 0;
    for (CFIndex index = 0; index < count; index++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, index);
        if (getFamilyID != NULL) {
            int familyID = 0;
            if (getFamilyID(device, &familyID) == 0 && isMagicMouseFamily(familyID)) {
                continue;
            }
        }
        registerCallback(device, touchFrameCallback);
        deviceStart(device, 0);
        started++;
    }

    if (started == 0) {
        writeError(errorBuffer, errorBufferLength, "No multitouch trackpad devices found");
        MSTrackpadStop();
        return false;
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
