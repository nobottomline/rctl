// Run the production Opus/speaker path against deterministic AudioQueue failures.
// No device, audio hardware, microphone, or network is used.
#include <AudioToolbox/AudioToolbox.h>
static decltype(AudioQueueNewOutput) fakeNewOutput;
static decltype(AudioQueueSetParameter) fakeSetParameter;
static decltype(AudioQueueStart) fakeStart;
static decltype(AudioQueueReset) fakeReset;
static decltype(AudioQueueAllocateBuffer) fakeAllocate;
static decltype(AudioQueueFreeBuffer) fakeFree;
static decltype(AudioQueueEnqueueBuffer) fakeEnqueue;
static decltype(AudioQueueGetProperty) fakeGetProperty;
#define AudioQueueNewOutput fakeNewOutput
#define AudioQueueSetParameter fakeSetParameter
#define AudioQueueStart fakeStart
#define AudioQueueReset fakeReset
#define AudioQueueAllocateBuffer fakeAllocate
#define AudioQueueFreeBuffer fakeFree
#define AudioQueueEnqueueBuffer fakeEnqueue
#define AudioQueueGetProperty fakeGetProperty
#include "../core/net/WebRTCBridge.cpp"
#include <cassert>
#include <cstdlib>

enum Failure { None, Create, Volume, Start, Reset, Allocate, Enqueue, Query };
static Failure failure = None;
static bool sessionOK = true, running = false;
static int starts = 0, allocations = 0, boosts = 0, virtualFrames = 0;
static int route = RCTL_TALK_SPEAKER;
static std::vector<AudioQueueBufferRef> queued;
static AudioQueueOutputCallback done;
extern "C" bool rctl_audio_session_activate(void) { return sessionOK; }
extern "C" void rctl_audio_boost_begin(void) { ++boosts; }
extern "C" void rctl_audio_boost_end(void) { --boosts; }
extern "C" int rctl_vmic_route(void) { return route; }
extern "C" void rctl_vmic_push(const int16_t *, int frames) { virtualFrames += frames; }

static OSStatus fakeNewOutput(const AudioStreamBasicDescription *, AudioQueueOutputCallback callback,
                             void *, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef *out) {
    if (failure == Create) return -50;
    done = callback;
    *out = reinterpret_cast<AudioQueueRef>(1);
    return noErr;
}
static OSStatus fakeSetParameter(AudioQueueRef, AudioQueueParameterID, AudioQueueParameterValue) {
    return failure == Volume ? -50 : noErr;
}
static OSStatus fakeStart(AudioQueueRef, const AudioTimeStamp *) {
    assert(!queued.empty()); // Never start an empty queue.
    ++starts;
    if (failure == Start) return -50;
    running = true;
    return noErr;
}
static OSStatus fakeReset(AudioQueueRef aq) {
    if (failure == Reset) return -50;
    auto buffers = std::move(queued);
    queued.clear();
    for (auto b : buffers) done(nullptr, aq, b);
    return noErr;
}
static OSStatus fakeAllocate(AudioQueueRef, UInt32 bytes, AudioQueueBufferRef *out) {
    if (failure == Allocate) return -50;
    static AudioStreamPacketDescription unused;
    *out = new AudioQueueBuffer(malloc(bytes), bytes, &unused, 0);
    ++allocations;
    return noErr;
}
static OSStatus fakeFree(AudioQueueRef, AudioQueueBufferRef buffer) {
    free(buffer->mAudioData);
    delete buffer;
    --allocations;
    return noErr;
}
static OSStatus fakeEnqueue(AudioQueueRef, AudioQueueBufferRef buffer, UInt32,
                            const AudioStreamPacketDescription *) {
    if (failure == Enqueue) return -50;
    queued.push_back(buffer);
    return noErr;
}
static OSStatus fakeGetProperty(AudioQueueRef, AudioQueuePropertyID id, void *out, UInt32 *) {
    assert(id == kAudioQueueProperty_IsRunning);
    if (failure == Query) return -50;
    *static_cast<UInt32 *>(out) = running;
    return noErr;
}

static std::vector<uint8_t> packet;
static void send() { mic_play_opus(packet.data(), packet.size()); }
static void nextBurst() {
    failure = None;
    mic_teardown();
    g_micLast = {};
    sessionOK = true;
    assert(boosts == 0 && allocations == 0 && g_micQueuedFrames.load() == 0);
}

int main() {
    g_micWatchStarted = true; // Deterministic tests, no detached watchdog thread.
    int err = 0;
    OpusEncoder *encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_AUDIO, &err);
    assert(err == OPUS_OK);
    int16_t pcm[960] = {};
    packet.resize(4096);
    int bytes = opus_encode(encoder, pcm, 960, packet.data(), (opus_int32)packet.size());
    assert(bytes > 0);
    packet.resize(bytes);
    opus_encoder_destroy(encoder);

    send();
    assert(starts == 1 && boosts == 1 && allocations == 1);
    nextBurst();
    send(); // A running persistent queue must not be started twice.
    assert(starts == 1);
    nextBurst();
    running = false; // Interruption between Talk attempts.
    send();
    assert(starts == 2 && !g_micSpeakerFailed);
    nextBurst();

    for (Failure f : {Create, Volume, Start, Reset, Allocate, Enqueue, Query}) {
        if (f == Create) g_micAQ = nullptr;
        running = false;
        failure = f;
        send();
        assert(g_micSpeakerFailed && boosts == 0 && allocations == 0);
        int before = starts;
        send(); // Continuous incoming packets must not flood retries.
        assert(starts == before && allocations == 0);
        nextBurst();
        send(); // A later explicit Talk attempt can recover.
        assert(!g_micSpeakerFailed && boosts == 1);
        nextBurst();
    }
    sessionOK = false;
    send();
    assert(g_micSpeakerFailed && boosts == 0 && allocations == 0);
    route = RCTL_TALK_BOTH;
    send(); // Speaker failure must not disable the independent app-mic route.
    assert(virtualFrames == 960);
    route = RCTL_TALK_SPEAKER;
    nextBurst();
    for (int i = 0; i < 100; ++i) send(); // Simulate a queue that never consumes.
    assert(g_micSpeakerFailed && allocations == 0 && boosts == 0);
    nextBurst();
    opus_decoder_destroy(g_micDec);
    puts("Talk speaker queue recovery, failure ownership and bounds passed");
}
