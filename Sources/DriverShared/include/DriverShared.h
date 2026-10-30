#ifndef DriverShared_h
#define DriverShared_h

// What the audio driver (Driver/ToolkitAudio.c) and the app share: the names
// that find the driver, and the memory the mix goes through. Everything that
// touches that memory is here, in C, because the driver and the app's audio
// thread need the same atomics, and Swift can't declare them over a mapping.

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define DRIVER_PLUGIN_BUNDLE_ID "dev.jalves.macos-toolkit.audio"
#define DRIVER_DEVICE_UID "dev.jalves.macos-toolkit.audio.device"
// On the plug-in object, a CFString: the name of the shared memory. Only
// answered to a process signed as the toolkit. 'tkln'.
#define DRIVER_LINK_SELECTOR 0x746B6C6Eu

#define DRIVER_SHARED_MAGIC 0x544B4144u // 'TKAD'
// Goes up when the layout changes, so an older driver says so rather than
// misbehaving.
#define DRIVER_SHARED_VERSION 1u
// A power of two. About 680 ms at 48 kHz, far more than is ever queued: the
// room is there so a stalled reader skips ahead rather than reading torn data.
#define DRIVER_RING_FRAMES 32768u
#define DRIVER_CHANNELS 2u
// Processes with a volume of their own, and clients of the device. Far more
// than ever play at once.
#define DRIVER_SLOTS 64u

// Written by the app: this process's volume. pid 0 is an empty slot.
typedef struct DriverSharedGain {
    int32_t pid;
    uint32_t gainBits;
} DriverSharedGain;

// Written by the driver: a client of the device, and the loudest it has been
// since the app last looked, which is before its volume, so a turned down app
// still counts as playing.
typedef struct DriverSharedClient {
    int32_t pid;
    uint32_t peakBits;
} DriverSharedClient;

typedef struct DriverSharedHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t capacity;
    uint32_t channels;
    uint8_t padding0[48];

    // Written by the driver. A cache line apart from the app's fields, so each
    // side's writes don't slow the other's reads on the audio thread. Padded by
    // hand: Swift can't import an over-aligned struct.
    uint64_t writeHead;
    uint64_t lastWriteTicks; // mach_absolute_time of the last write
    uint32_t lastWriteFrames;
    uint32_t ioRunning;
    uint8_t padding1[40];

    // Written by the app.
    uint64_t heartbeat; // mach_absolute_time
    uint64_t rateBits;  // a double: the driver's clock against the host's
    uint32_t closing;
    uint32_t latencyFrames; // what the device reports: the queue and the real output's own
    uint8_t padding2[40];

    DriverSharedGain gains[DRIVER_SLOTS];       // by the app
    DriverSharedClient clients[DRIVER_SLOTS];   // by the driver
} DriverSharedHeader;

_Static_assert(sizeof(DriverSharedHeader) % 64 == 0, "whole cache lines");

// The app's way in (DriverShared.c): shm_open is variadic, which Swift can't
// call. NULL, with `error` set, if it doesn't open.
DriverSharedHeader *driver_shared_open(const char *name, int *error);

static inline size_t driver_shared_size(void) {
    return sizeof(DriverSharedHeader) + (size_t)DRIVER_RING_FRAMES * DRIVER_CHANNELS * sizeof(float);
}

static inline float *driver_shared_samples(DriverSharedHeader *shared) {
    return (float *)(void *)(shared + 1);
}

static inline void driver_shared_init(DriverSharedHeader *shared) {
    memset(shared, 0, driver_shared_size());
    shared->capacity = DRIVER_RING_FRAMES;
    shared->channels = DRIVER_CHANNELS;
    double one = 1;
    memcpy(&shared->rateBits, &one, sizeof one);
    shared->version = DRIVER_SHARED_VERSION;
    // Last, and released: whoever sees the magic sees the rest.
    atomic_store_explicit((_Atomic uint32_t *)&shared->magic, DRIVER_SHARED_MAGIC, memory_order_release);
}

static inline bool driver_shared_is_valid(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint32_t *)&shared->magic, memory_order_acquire) == DRIVER_SHARED_MAGIC
        && shared->version == DRIVER_SHARED_VERSION && shared->capacity == DRIVER_RING_FRAMES && shared->channels == DRIVER_CHANNELS;
}

// The driver's audio thread: one writer.
static inline void driver_shared_write(DriverSharedHeader *shared, const float *frames, uint32_t count, uint64_t ticks) {
    uint64_t head = atomic_load_explicit((_Atomic uint64_t *)&shared->writeHead, memory_order_relaxed);
    if (count > DRIVER_RING_FRAMES) count = DRIVER_RING_FRAMES;
    uint32_t start = (uint32_t)(head & (DRIVER_RING_FRAMES - 1));
    uint32_t first = count < DRIVER_RING_FRAMES - start ? count : DRIVER_RING_FRAMES - start;
    float *samples = driver_shared_samples(shared);
    memcpy(samples + start * DRIVER_CHANNELS, frames, first * DRIVER_CHANNELS * sizeof(float));
    memcpy(samples, frames + first * DRIVER_CHANNELS, (count - first) * DRIVER_CHANNELS * sizeof(float));
    atomic_store_explicit((_Atomic uint64_t *)&shared->lastWriteTicks, ticks, memory_order_relaxed);
    atomic_store_explicit((_Atomic uint32_t *)&shared->lastWriteFrames, count, memory_order_relaxed);
    atomic_store_explicit((_Atomic uint64_t *)&shared->writeHead, head + count, memory_order_release);
}

static inline uint64_t driver_shared_write_head(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint64_t *)&shared->writeHead, memory_order_acquire);
}

static inline uint64_t driver_shared_last_write_ticks(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint64_t *)&shared->lastWriteTicks, memory_order_acquire);
}

static inline uint32_t driver_shared_last_write_frames(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint32_t *)&shared->lastWriteFrames, memory_order_relaxed);
}

// The app's audio thread: `position` is its own, and within the capacity of
// the write head.
static inline void driver_shared_read(DriverSharedHeader *shared, uint64_t position, float *frames, uint32_t count) {
    if (count > DRIVER_RING_FRAMES) count = DRIVER_RING_FRAMES;
    uint32_t start = (uint32_t)(position & (DRIVER_RING_FRAMES - 1));
    uint32_t first = count < DRIVER_RING_FRAMES - start ? count : DRIVER_RING_FRAMES - start;
    const float *samples = driver_shared_samples(shared);
    memcpy(frames, samples + start * DRIVER_CHANNELS, first * DRIVER_CHANNELS * sizeof(float));
    memcpy(frames + first * DRIVER_CHANNELS, samples, (count - first) * DRIVER_CHANNELS * sizeof(float));
}

static inline void driver_shared_set_rate(DriverSharedHeader *shared, double rate) {
    uint64_t bits;
    memcpy(&bits, &rate, sizeof bits);
    atomic_store_explicit((_Atomic uint64_t *)&shared->rateBits, bits, memory_order_relaxed);
}

static inline double driver_shared_rate(DriverSharedHeader *shared) {
    uint64_t bits = atomic_load_explicit((_Atomic uint64_t *)&shared->rateBits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &bits, sizeof rate);
    return rate;
}

static inline void driver_shared_set_heartbeat(DriverSharedHeader *shared, uint64_t ticks) {
    atomic_store_explicit((_Atomic uint64_t *)&shared->heartbeat, ticks, memory_order_relaxed);
}

static inline uint64_t driver_shared_heartbeat(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint64_t *)&shared->heartbeat, memory_order_relaxed);
}

static inline void driver_shared_set_closing(DriverSharedHeader *shared, bool closing) {
    atomic_store_explicit((_Atomic uint32_t *)&shared->closing, closing ? 1 : 0, memory_order_relaxed);
}

static inline bool driver_shared_closing(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint32_t *)&shared->closing, memory_order_relaxed) != 0;
}

static inline void driver_shared_set_latency(DriverSharedHeader *shared, uint32_t frames) {
    atomic_store_explicit((_Atomic uint32_t *)&shared->latencyFrames, frames, memory_order_relaxed);
}

static inline uint32_t driver_shared_latency(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint32_t *)&shared->latencyFrames, memory_order_relaxed);
}

// The app's table of volumes. The gain before the pid, so a new pid never
// meets the volume of the one before it.
static inline void driver_shared_set_gain(DriverSharedHeader *shared, uint32_t slot, int32_t pid, float gain) {
    uint32_t bits;
    memcpy(&bits, &gain, sizeof bits);
    atomic_store_explicit((_Atomic uint32_t *)&shared->gains[slot].gainBits, bits, memory_order_relaxed);
    atomic_store_explicit((_Atomic int32_t *)&shared->gains[slot].pid, pid, memory_order_release);
}

// The driver's audio thread: 1 for a process with no volume of its own.
static inline float driver_shared_gain_of(DriverSharedHeader *shared, int32_t pid) {
    for (uint32_t slot = 0; slot < DRIVER_SLOTS; slot++) {
        if (atomic_load_explicit((_Atomic int32_t *)&shared->gains[slot].pid, memory_order_acquire) == pid) {
            uint32_t bits = atomic_load_explicit((_Atomic uint32_t *)&shared->gains[slot].gainBits, memory_order_relaxed);
            float gain;
            memcpy(&gain, &bits, sizeof gain);
            return gain >= 0 && gain <= 1 ? gain : 1;
        }
    }
    return 1;
}

static inline void driver_shared_set_client(DriverSharedHeader *shared, uint32_t slot, int32_t pid) {
    atomic_store_explicit((_Atomic uint32_t *)&shared->clients[slot].peakBits, 0, memory_order_relaxed);
    atomic_store_explicit((_Atomic int32_t *)&shared->clients[slot].pid, pid, memory_order_release);
}

static inline int32_t driver_shared_client(DriverSharedHeader *shared, uint32_t slot) {
    return atomic_load_explicit((_Atomic int32_t *)&shared->clients[slot].pid, memory_order_acquire);
}

static inline void driver_shared_note_peak(DriverSharedHeader *shared, uint32_t slot, float peak) {
    uint32_t last = atomic_load_explicit((_Atomic uint32_t *)&shared->clients[slot].peakBits, memory_order_relaxed);
    float before;
    memcpy(&before, &last, sizeof before);
    if (peak > before) {
        uint32_t bits;
        memcpy(&bits, &peak, sizeof bits);
        atomic_store_explicit((_Atomic uint32_t *)&shared->clients[slot].peakBits, bits, memory_order_relaxed);
    }
}

static inline float driver_shared_take_peak(DriverSharedHeader *shared, uint32_t slot) {
    uint32_t bits = atomic_exchange_explicit((_Atomic uint32_t *)&shared->clients[slot].peakBits, 0, memory_order_relaxed);
    float peak;
    memcpy(&peak, &bits, sizeof peak);
    return peak;
}

static inline bool driver_shared_io_running(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint32_t *)&shared->ioRunning, memory_order_relaxed) != 0;
}

// How many of the `limit` frames from `position` are silent, to the first that
// isn't: an app often plays silence as it starts, and nothing need wait for that.
static inline uint32_t driver_shared_leading_silence(DriverSharedHeader *shared, uint64_t position, uint32_t limit) {
    const float *samples = driver_shared_samples(shared);
    for (uint32_t frame = 0; frame < limit; frame++) {
        uint32_t at = (uint32_t)((position + frame) & (DRIVER_RING_FRAMES - 1)) * DRIVER_CHANNELS;
        if (samples[at] > 0.00001f || samples[at] < -0.00001f || samples[at + 1] > 0.00001f || samples[at + 1] < -0.00001f) return frame;
    }
    return limit;
}

static inline void driver_shared_set_io_running(DriverSharedHeader *shared, bool running) {
    atomic_store_explicit((_Atomic uint32_t *)&shared->ioRunning, running ? 1 : 0, memory_order_relaxed);
}

#endif
