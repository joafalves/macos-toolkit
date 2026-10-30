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
    uint32_t ioRunning;
    uint8_t padding1[52];

    // Written by the app.
    uint64_t heartbeat; // mach_absolute_time
    uint64_t rateBits;  // a double: the driver's clock against the host's
    uint32_t closing;
    uint8_t padding2[44];
} DriverSharedHeader;

_Static_assert(sizeof(DriverSharedHeader) == 192, "three cache lines");

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
static inline void driver_shared_write(DriverSharedHeader *shared, const float *frames, uint32_t count) {
    uint64_t head = atomic_load_explicit((_Atomic uint64_t *)&shared->writeHead, memory_order_relaxed);
    if (count > DRIVER_RING_FRAMES) count = DRIVER_RING_FRAMES;
    uint32_t start = (uint32_t)(head & (DRIVER_RING_FRAMES - 1));
    uint32_t first = count < DRIVER_RING_FRAMES - start ? count : DRIVER_RING_FRAMES - start;
    float *samples = driver_shared_samples(shared);
    memcpy(samples + start * DRIVER_CHANNELS, frames, first * DRIVER_CHANNELS * sizeof(float));
    memcpy(samples, frames + first * DRIVER_CHANNELS, (count - first) * DRIVER_CHANNELS * sizeof(float));
    atomic_store_explicit((_Atomic uint64_t *)&shared->writeHead, head + count, memory_order_release);
}

static inline uint64_t driver_shared_write_head(DriverSharedHeader *shared) {
    return atomic_load_explicit((_Atomic uint64_t *)&shared->writeHead, memory_order_acquire);
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

static inline void driver_shared_set_io_running(DriverSharedHeader *shared, bool running) {
    atomic_store_explicit((_Atomic uint32_t *)&shared->ioRunning, running ? 1 : 0, memory_order_relaxed);
}

#endif
