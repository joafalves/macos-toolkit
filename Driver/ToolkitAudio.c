// The Audio Mixer's driver: an AudioServerPlugIn with one output-only device.
// Apps play to it, and the mix goes through shared memory to the toolkit, which
// plays it on the real output. Nothing records, so macOS shows no privacy dot.
//
// The device exists only while the toolkit is there. It asks for the shared
// memory's name through a property on the plug-in object, and the device shows
// once it has opened that memory. If it quits, crashes or hangs, the device
// goes, and macOS moves sound back to a real output: nothing is left silent.
//
// It runs in coreaudiod's helper for drivers, sandboxed, and a bug here stops
// sound for the whole Mac, so it does as little as it can: no allocation, no
// logging and only the shortest locks on the audio thread.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <os/log.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "DriverShared.h"

// From build.sh: the requirement for who gets the shared memory's name.
#ifndef TOOLKIT_REQUIREMENT
#error "TOOLKIT_REQUIREMENT is set by build.sh"
#endif

enum { kObjectDevice = 2, kObjectStream = 3 };

static const Float64 kSampleRates[] = {44100, 48000, 88200, 96000, 176400, 192000};
enum { kSampleRateCount = sizeof kSampleRates / sizeof kSampleRates[0] };
// Frames between zero time stamps: as Apple's sample, which leaves the host
// plenty to fit its clock to.
enum { kZeroTimeStampPeriod = 16384 };

static AudioServerPlugInHostRef gHost;
static _Atomic ULONG gRefCount = 1;
static os_log_t gLog;

// The rest of the device's state. gLock covers the clock, between StartIO,
// StopIO and the audio thread.
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static Float64 gSampleRate = 48000;
static Float64 gHostTicksPerSecond;
static UInt32 gIOClients;
static Float64 gAnchorHost;
static Float64 gAnchorSample;

// The link with the toolkit. gLinkQueue covers what isn't atomic.
static dispatch_queue_t gLinkQueue;
static dispatch_source_t gWatch;
static _Atomic(DriverSharedHeader *) gShared;
static char gSharedName[32];
static bool gNameLinked;
static uint64_t gHandedOutBeat;
static pid_t gLinkPid;
static _Atomic bool gPublished;

#pragma mark - The link

// No longer than this without a beat and the toolkit is hung. Not short: a
// busy Mac can hold its timer back, and hiding the device moves all sound off
// it. A toolkit that's gone is noticed within a second, from its process.
static const double kStaleSeconds = 15;

static uint64_t SecondsToTicks(double seconds) {
    return (uint64_t)(seconds * gHostTicksPerSecond);
}

static void NotifyDeviceList(void) {
    const AudioObjectPropertyAddress changed[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    gHost->PropertiesChanged(gHost, kAudioObjectPlugInObject, 2, changed);
}

static void WatchEvery(double seconds) {
    dispatch_source_set_timer(gWatch, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              (uint64_t)(seconds * NSEC_PER_SEC), (uint64_t)(seconds * NSEC_PER_SEC / 5));
}

// On gLinkQueue.
static void Unpublish(const char *why) {
    os_log(gLog, "link over: %{public}s", why);
    if (gWatch) {
        dispatch_source_cancel(gWatch);
        gWatch = NULL;
    }
    gLinkPid = 0;
    if (atomic_exchange(&gPublished, false)) NotifyDeviceList();
}

// On gLinkQueue, every so often while linked.
static void Watch(void) {
    DriverSharedHeader *shared = atomic_load(&gShared);
    if (!shared) return Unpublish("no memory");
    uint64_t beat = driver_shared_heartbeat(shared);
    if (driver_shared_closing(shared)) return Unpublish("the toolkit closed it");
    if (kill(gLinkPid, 0) == -1 && errno == ESRCH) return Unpublish("the toolkit is gone");
    if (mach_absolute_time() - beat > SecondsToTicks(kStaleSeconds)) return Unpublish("no heartbeat");
    if (beat != gHandedOutBeat) {
        // It has the memory open: nobody else needs the name, and with it
        // unlinked the memory goes with the last of us.
        if (gNameLinked) {
            shm_unlink(gSharedName);
            gNameLinked = false;
        }
        if (!atomic_exchange(&gPublished, true)) {
            os_log(gLog, "device shown, for pid %d", gLinkPid);
            NotifyDeviceList();
            WatchEvery(1);
        }
    }
}

// On gLinkQueue. A new region each time, so a name once given can't reach the
// memory of a later link. An old region is left mapped: the audio thread could
// be in it, and it's small and only happens when the toolkit starts over.
static bool MakeShared(void) {
    uint8_t bytes[12];
    arc4random_buf(bytes, sizeof bytes);
    int used = snprintf(gSharedName, sizeof gSharedName, "/tk");
    for (size_t i = 0; i < sizeof bytes; i++) used += snprintf(gSharedName + used, sizeof gSharedName - (size_t)used, "%02x", bytes[i]);

    int fd = shm_open(gSharedName, O_CREAT | O_EXCL | O_RDWR, 0666);
    if (fd < 0) {
        os_log_error(gLog, "shm_open: %{public}s", strerror(errno));
        return false;
    }
    // Not left to the umask: the driver and the toolkit run as different users.
    // The name is the secret, kept from everyone but the toolkit.
    if (fchmod(fd, 0666) != 0 || ftruncate(fd, (off_t)driver_shared_size()) != 0) {
        os_log_error(gLog, "shared memory setup: %{public}s", strerror(errno));
        close(fd);
        shm_unlink(gSharedName);
        return false;
    }
    void *memory = mmap(NULL, driver_shared_size(), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (memory == MAP_FAILED) {
        os_log_error(gLog, "mmap: %{public}s", strerror(errno));
        shm_unlink(gSharedName);
        return false;
    }
    driver_shared_init(memory);
    gNameLinked = true;
    atomic_store(&gShared, (DriverSharedHeader *)memory);
    return true;
}

static bool CallerIsToolkit(pid_t pid) {
    bool allowed = false;
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = {kSecGuestAttributePid};
    const void *values[] = {number};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    if (status != errSecSuccess) {
        os_log_error(gLog, "signature of pid %d: finding the code: %d", pid, (int)status);
    } else if ((status = SecRequirementCreateWithString(CFSTR(TOOLKIT_REQUIREMENT), kSecCSDefaultFlags, &requirement)) != errSecSuccess) {
        os_log_error(gLog, "signature of pid %d: the requirement: %d", pid, (int)status);
    } else if ((status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement)) != errSecSuccess) {
        os_log_error(gLog, "signature of pid %d: refused: %d", pid, (int)status);
    } else {
        allowed = true;
    }
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    CFRelease(attributes);
    CFRelease(number);
    return allowed;
}

// The answer to the link property: the memory's name, for the toolkit only.
static CFStringRef CopyLinkName(pid_t pid) {
    if (!CallerIsToolkit(pid)) return NULL;
    __block CFStringRef name = NULL;
    dispatch_sync(gLinkQueue, ^{
        if (!MakeShared()) return;
        DriverSharedHeader *shared = atomic_load(&gShared);
        gHandedOutBeat = mach_absolute_time();
        driver_shared_set_heartbeat(shared, gHandedOutBeat);
        gLinkPid = pid;
        if (!gWatch) {
            gWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gLinkQueue);
            dispatch_source_set_event_handler(gWatch, ^{ Watch(); });
            dispatch_activate(gWatch);
        }
        // Quickly until the device shows, then slowly.
        WatchEvery(0.1);
        name = CFStringCreateWithCString(NULL, gSharedName, kCFStringEncodingUTF8);
        os_log(gLog, "memory given to pid %d", pid);
    });
    return name;
}

#pragma mark - Properties

// Answers every property from one place, for size and value alike: `out` nil
// asks only the size, and whether it's there at all. Sizes that disagree with
// the value are how these drivers crash the host, so there's one table.
#define ANSWER(type, value)                                                       \
    do {                                                                          \
        if (outSize) *outSize = sizeof(type);                                     \
        if (out) {                                                                \
            if (capacity < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type *)out = (value);                                               \
        }                                                                         \
        return kAudioHardwareNoError;                                             \
    } while (0)

#define ANSWER_LIST(type, items, count)                                           \
    do {                                                                          \
        UInt32 fits = out ? capacity / (UInt32)sizeof(type) : (UInt32)(count);    \
        UInt32 used = (UInt32)(count) < fits ? (UInt32)(count) : fits;            \
        if (outSize) *outSize = used * (UInt32)sizeof(type);                      \
        if (out && used > 0) memcpy(out, (items), used * sizeof(type));           \
        return kAudioHardwareNoError;                                             \
    } while (0)

static AudioStreamBasicDescription Format(Float64 rate) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = DRIVER_CHANNELS * sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = DRIVER_CHANNELS * sizeof(Float32);
    format.mChannelsPerFrame = DRIVER_CHANNELS;
    format.mBitsPerChannel = 32;
    return format;
}

static Float64 CurrentRate(void) {
    os_unfair_lock_lock(&gLock);
    Float64 rate = gSampleRate;
    os_unfair_lock_unlock(&gLock);
    return rate;
}

static OSStatus PlugInProperty(pid_t pid, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                               UInt32 capacity, UInt32 *outSize, void *out) {
    bool published = atomic_load(&gPublished);
    AudioObjectID device = kObjectDevice;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: ANSWER(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: ANSWER(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: ANSWER(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: ANSWER(CFStringRef, CFSTR("MacOS Toolkit"));
    case kAudioPlugInPropertyResourceBundle: ANSWER(CFStringRef, CFSTR(""));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: ANSWER_LIST(AudioObjectID, &device, published ? 1 : 0);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (!out) ANSWER(AudioObjectID, kAudioObjectUnknown);
        if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
        bool same = published && CFStringCompare(*(const CFStringRef *)qualifier, CFSTR(DRIVER_DEVICE_UID), 0) == kCFCompareEqualTo;
        ANSWER(AudioObjectID, same ? (AudioObjectID)kObjectDevice : (AudioObjectID)kAudioObjectUnknown);
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo info = {DRIVER_LINK_SELECTOR, kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone};
        ANSWER_LIST(AudioServerPlugInCustomPropertyInfo, &info, 1);
    }
    case DRIVER_LINK_SELECTOR: {
        if (!out) ANSWER(CFStringRef, NULL);
        CFStringRef name = CopyLinkName(pid);
        if (!name) return kAudioHardwareIllegalOperationError;
        ANSWER(CFStringRef, name);
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress *address, UInt32 capacity, UInt32 *outSize, void *out) {
    AudioObjectID stream = kObjectStream;
    AudioObjectID device = kObjectDevice;
    bool output = address->mScope != kAudioObjectPropertyScopeInput;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: ANSWER(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: ANSWER(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: ANSWER(AudioObjectID, kAudioObjectPlugInObject);
    case kAudioObjectPropertyName: ANSWER(CFStringRef, CFSTR("MacOS Toolkit"));
    case kAudioObjectPropertyManufacturer: ANSWER(CFStringRef, CFSTR("MacOS Toolkit"));
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams: ANSWER_LIST(AudioObjectID, &stream, output ? 1 : 0);
    case kAudioObjectPropertyControlList: ANSWER_LIST(AudioObjectID, &stream, 0);
    case kAudioDevicePropertyDeviceUID: ANSWER(CFStringRef, CFSTR(DRIVER_DEVICE_UID));
    case kAudioDevicePropertyModelUID: ANSWER(CFStringRef, CFSTR("dev.jalves.macos-toolkit.audio.model"));
    case kAudioDevicePropertyTransportType: ANSWER(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: ANSWER_LIST(AudioObjectID, &device, 1);
    case kAudioDevicePropertyClockDomain: ANSWER(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: ANSWER(UInt32, atomic_load(&gPublished) ? 1 : 0);
    case kAudioDevicePropertyDeviceIsRunning: {
        if (!out) ANSWER(UInt32, 0);
        os_unfair_lock_lock(&gLock);
        UInt32 running = gIOClients > 0;
        os_unfair_lock_unlock(&gLock);
        ANSWER(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: ANSWER(UInt32, output ? 1 : 0);
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset: ANSWER(UInt32, 0);
    case kAudioDevicePropertyNominalSampleRate: ANSWER(Float64, CurrentRate());
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange ranges[kSampleRateCount];
        for (int i = 0; i < kSampleRateCount; i++) ranges[i] = (AudioValueRange){kSampleRates[i], kSampleRates[i]};
        ANSWER_LIST(AudioValueRange, ranges, kSampleRateCount);
    }
    case kAudioDevicePropertyIsHidden: ANSWER(UInt32, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: ANSWER(UInt32, kZeroTimeStampPeriod);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32 channels[2] = {1, 2};
        ANSWER_LIST(UInt32, channels, 2);
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions);
        if (outSize) *outSize = size;
        if (out) {
            if (capacity < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = out;
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            layout->mChannelBitmap = 0;
            layout->mNumberChannelDescriptions = 0;
        }
        return kAudioHardwareNoError;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus StreamProperty(const AudioObjectPropertyAddress *address, UInt32 capacity, UInt32 *outSize, void *out) {
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: ANSWER(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: ANSWER(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: ANSWER(AudioObjectID, kObjectDevice);
    case kAudioObjectPropertyOwnedObjects: ANSWER_LIST(AudioObjectID, NULL, 0);
    case kAudioStreamPropertyIsActive: ANSWER(UInt32, 1);
    case kAudioStreamPropertyDirection: ANSWER(UInt32, 0);
    case kAudioStreamPropertyTerminalType: ANSWER(UInt32, kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: ANSWER(UInt32, 1);
    case kAudioStreamPropertyLatency: ANSWER(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: ANSWER(AudioStreamBasicDescription, Format(CurrentRate()));
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription formats[kSampleRateCount];
        for (int i = 0; i < kSampleRateCount; i++) {
            formats[i].mFormat = Format(kSampleRates[i]);
            formats[i].mSampleRateRange = (AudioValueRange){kSampleRates[i], kSampleRates[i]};
        }
        ANSWER_LIST(AudioStreamRangedDescription, formats, kSampleRateCount);
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Property(AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                         const void *qualifier, UInt32 capacity, UInt32 *outSize, void *out) {
    switch (object) {
    case kAudioObjectPlugInObject: return PlugInProperty(pid, address, qualifierSize, qualifier, capacity, outSize, out);
    case kObjectDevice: return DeviceProperty(address, capacity, outSize, out);
    case kObjectStream: return StreamProperty(address, capacity, outSize, out);
    }
    return kAudioHardwareBadObjectError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address) {
    (void)driver;
    UInt32 size = 0;
    return Property(object, pid, address, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                                   const AudioObjectPropertyAddress *address, Boolean *outSettable) {
    (void)driver;
    UInt32 size = 0;
    OSStatus status = Property(object, pid, address, 0, NULL, 0, &size, NULL);
    if (status != kAudioHardwareNoError) return status;
    AudioObjectPropertySelector selector = address->mSelector;
    *outSettable = (object == kObjectDevice && selector == kAudioDevicePropertyNominalSampleRate)
        || (object == kObjectStream && (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat));
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierSize, const void *qualifier, UInt32 *outSize) {
    (void)driver;
    return Property(object, pid, address, qualifierSize, qualifier, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address,
                                UInt32 qualifierSize, const void *qualifier, UInt32 capacity, UInt32 *outSize, void *out) {
    (void)driver;
    return Property(object, pid, address, qualifierSize, qualifier, capacity, outSize, out);
}

static OSStatus RequestRate(Float64 rate) {
    bool known = false;
    for (int i = 0; i < kSampleRateCount; i++) known = known || kSampleRates[i] == rate;
    if (!known) return kAudioHardwareIllegalOperationError;
    if (rate == CurrentRate()) return kAudioHardwareNoError;
    // The host stops IO and then calls PerformDeviceConfigurationChange. Not
    // from inside a property call, which it may be holding a lock for.
    dispatch_async(gLinkQueue, ^{
        gHost->RequestDeviceConfigurationChange(gHost, kObjectDevice, (UInt64)rate, NULL);
    });
    return kAudioHardwareNoError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address,
                                UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    (void)driver, (void)pid, (void)qualifierSize, (void)qualifier;
    if (object == kObjectDevice && address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return RequestRate(*(const Float64 *)data);
    }
    if (object == kObjectStream && (address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *format = data;
        AudioStreamBasicDescription ours = Format(format->mSampleRate);
        if (format->mFormatID != ours.mFormatID || format->mChannelsPerFrame != ours.mChannelsPerFrame || format->mBitsPerChannel != ours.mBitsPerChannel)
            return kAudioDeviceUnsupportedFormatError;
        return RequestRate(format->mSampleRate);
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static void ResetClock(void) {
    gAnchorHost = (Float64)mach_absolute_time();
    gAnchorSample = 0;
}

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)driver, (void)client;
    if (device != kObjectDevice) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gLock);
    if (gIOClients == 0) ResetClock();
    gIOClients++;
    os_unfair_lock_unlock(&gLock);
    DriverSharedHeader *shared = atomic_load(&gShared);
    if (shared) driver_shared_set_io_running(shared, true);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    (void)driver, (void)client;
    if (device != kObjectDevice) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gLock);
    bool last = gIOClients <= 1;
    if (gIOClients > 0) gIOClients--;
    os_unfair_lock_unlock(&gLock);
    DriverSharedHeader *shared = atomic_load(&gShared);
    if (last && shared) driver_shared_set_io_running(shared, false);
    return kAudioHardwareNoError;
}

// The device's clock. Against the host's by default; with the toolkit there,
// the rate it writes follows the real output, so the two never drift apart and
// nothing needs resampling. Each period is laid from the last, so a change of
// rate never makes time jump.
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)driver, (void)client;
    if (device != kObjectDevice) return kAudioHardwareBadObjectError;
    DriverSharedHeader *shared = atomic_load(&gShared);
    double rate = shared ? driver_shared_rate(shared) : 1;
    // Nothing the toolkit writes can stop the clock.
    if (!(rate > 0.99 && rate < 1.01)) rate = 1;
    os_unfair_lock_lock(&gLock);
    Float64 ticksPerPeriod = gHostTicksPerSecond * kZeroTimeStampPeriod / (gSampleRate * rate);
    Float64 now = (Float64)mach_absolute_time();
    // Several periods only after a long stall.
    while (gAnchorHost + ticksPerPeriod <= now) {
        gAnchorHost += ticksPerPeriod;
        gAnchorSample += kZeroTimeStampPeriod;
    }
    *outSampleTime = gAnchorSample;
    *outHostTime = (UInt64)gAnchorHost;
    os_unfair_lock_unlock(&gLock);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation,
                                  Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)driver, (void)client;
    if (device != kObjectDevice) return kAudioHardwareBadObjectError;
    *outWillDo = operation == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames,
                                 const AudioServerPlugInIOCycleInfo *cycle) {
    (void)driver, (void)device, (void)client, (void)operation, (void)frames, (void)cycle;
    return kAudioHardwareNoError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream, UInt32 client, UInt32 operation,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    (void)driver, (void)stream, (void)client, (void)cycle, (void)secondaryBuffer;
    if (device != kObjectDevice) return kAudioHardwareBadObjectError;
    if (operation == kAudioServerPlugInIOOperationWriteMix) {
        DriverSharedHeader *shared = atomic_load(&gShared);
        if (shared) driver_shared_write(shared, mainBuffer, frames);
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames,
                               const AudioServerPlugInIOCycleInfo *cycle) {
    (void)driver, (void)device, (void)client, (void)operation, (void)frames, (void)cycle;
    return kAudioHardwareNoError;
}

#pragma mark - The plug-in

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    (void)driver;
    gHost = host;
    gLog = os_log_create("dev.jalves.macos-toolkit", "driver");
    gLinkQueue = dispatch_queue_create("dev.jalves.macos-toolkit.audio.link", DISPATCH_QUEUE_SERIAL);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    os_log(gLog, "driver loaded");
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description, const AudioServerPlugInClientInfo *client, AudioObjectID *outDevice) {
    (void)driver, (void)description, (void)client, (void)outDevice;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID device) {
    (void)driver, (void)device;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo *client) {
    (void)driver, (void)device, (void)client;
    return kAudioHardwareNoError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID device, const AudioServerPlugInClientInfo *client) {
    (void)driver, (void)device, (void)client;
    return kAudioHardwareNoError;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void *info) {
    (void)driver, (void)info;
    if (device != kObjectDevice) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gLock);
    gSampleRate = (Float64)action;
    ResetClock();
    os_unfair_lock_unlock(&gLock);
    return kAudioHardwareNoError;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt64 action, void *info) {
    (void)driver, (void)device, (void)action, (void)info;
    return kAudioHardwareNoError;
}

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface);

static ULONG AddRef(void *driver) {
    (void)driver;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Release(void *driver) {
    (void)driver;
    ULONG count = atomic_load(&gRefCount);
    while (count > 0 && !atomic_compare_exchange_weak(&gRefCount, &count, count - 1)) {}
    return count > 0 ? count - 1 : 0;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;

static HRESULT QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface) {
    if (driver != gDriver || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    bool known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) return E_NOINTERFACE;
    AddRef(driver);
    *outInterface = gDriver;
    return S_OK;
}

__attribute__((visibility("default")))
void *ToolkitAudio_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    (void)allocator;
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}
