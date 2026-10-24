#include "../tv/overlay/entry/src/main/cpp/audio/matetv_remote_audio_gain.h"
#include <cassert>
#include <limits>
#include <vector>

using MateTv::RemoteAudioGain;
static constexpr int rate = 48000;
static int sample(const std::vector<uint8_t>& bytes, size_t index) {
    const unsigned raw = bytes[index * 2] | (unsigned(bytes[index * 2 + 1]) << 8);
    return raw >= 32768 ? static_cast<int>(raw) - 65536 : static_cast<int>(raw);
}
static void put(std::vector<uint8_t>& bytes, size_t index, int value) {
    const uint16_t raw = static_cast<uint16_t>(value);
    bytes[index * 2] = raw & 255U;
    bytes[index * 2 + 1] = raw >> 8;
}
static std::vector<uint8_t> constant(int frames, int left, int right) {
    std::vector<uint8_t> bytes(static_cast<size_t>(frames) * 4);
    for (int frame=0; frame<frames; ++frame) {
        put(bytes, frame*2, left); put(bytes, frame*2+1, right);
    }
    return bytes;
}
static void process(RemoteAudioGain& gain, std::vector<uint8_t>& bytes) {
    gain.process(bytes.data(),bytes.size(),2,rate);
}

int main() {
    { // Default/reset is exactly transparent, including signed extrema and incomplete frames.
        RemoteAudioGain gain;
        auto bytes = constant(100,-32768,32767); bytes.push_back(213);
        const auto original = bytes; process(gain,bytes); assert(bytes == original);
        gain.setDb(30); auto warmup=constant(rate,100,100); process(gain,warmup);
        gain.setDb(0); process(gain,bytes); assert(bytes == original);
    }
    { // Quiet content gets the requested dB gain without engaging the limiter.
        RemoteAudioGain gain; assert(gain.setDb(6));
        auto bytes=constant(rate,1000,-500); process(gain,bytes);
        assert(sample(bytes,0)>=1000 && sample(bytes,0)<1005); // No sudden gain jump.
        assert(std::abs(sample(bytes,(rate-1)*2)-1995)<=2);
        assert(std::abs(sample(bytes,(rate-1)*2+1)+998)<=2);
        assert(gain.setDb(30)); bytes=constant(rate,200,-100); process(gain,bytes);
        assert(std::abs(sample(bytes,(rate-1)*2)-6325)<=10);
        assert(gain.setDb(60)); bytes=constant(rate,5,-10); process(gain,bytes);
        assert(std::abs(sample(bytes,(rate-1)*2)-5000)<=5);
        assert(std::abs(sample(bytes,(rate-1)*2+1)+10000)<=10);
    }
    { // Loud peaks have linked stereo attenuation, never per-channel hard clipping.
        RemoteAudioGain gain; gain.setDb(30);
        auto warmup=constant(rate,100,-50); process(gain,warmup);
        auto bytes=constant(rate/4,32766,-16383);
        for (int frame=1;frame<rate/4;frame+=2) {
            put(bytes,frame*2,-30000); put(bytes,frame*2+1,15000);
        }
        process(gain,bytes);
        for (int frame=0;frame<rate/4;++frame) {
            const int left=sample(bytes,frame*2), right=sample(bytes,frame*2+1);
            assert(std::abs(left)<=29490 && std::abs(right)<=29490);
            assert(std::abs(left+2*right)<=1); // Preserve image and channel ratio.
        }
        assert(sample(bytes,2) < 0 && std::abs(sample(bytes,2)) < sample(bytes,0));
    }
    { // Maximum supported boost still bounds extreme PCM without wrapping or channel imbalance.
        RemoteAudioGain gain; assert(gain.setDb(60));
        auto warmup=constant(rate,5,-10); process(gain,warmup);
        auto peaks=constant(rate/4,-32768,16384); process(gain,peaks);
        for (int frame=0; frame<rate/4; ++frame) {
            const int left=sample(peaks,frame*2), right=sample(peaks,frame*2+1);
            assert(left<0 && right>0);
            assert(std::abs(left)<=29490 && std::abs(right)<=29490);
            assert(std::abs(left+2*right)<=1);
        }
    }
    { // A full-scale transient cannot overshoot; recovery takes time, not one sample.
        RemoteAudioGain gain; gain.setDb(30);
        auto warmup=constant(rate,100,100); process(gain,warmup);
        auto transient=constant(1,-32768,32767); process(gain,transient);
        assert(std::abs(sample(transient,0))<=29490);
        auto recovery=constant(rate/5,100,100); process(gain,recovery);
        assert(sample(recovery,0)<200);
        const int last=sample(recovery,(rate/5-1)*2);
        assert(last>1800 && last<2400);
        for(int frame=1;frame<rate/5;++frame) {
            assert(sample(recovery,frame*2)>=sample(recovery,(frame-1)*2));
        }
    }
    { // Envelope state persists across callback boundaries: chunking cannot change sound.
        auto whole=constant(rate,200,-100);
        for (int frame=1000;frame<1100;frame++) { put(whole,frame*2,32767); }
        auto chunks=whole;
        RemoteAudioGain a,b; a.setDb(24); b.setDb(24); process(a,whole);
        for (size_t offset=0;offset<chunks.size();offset+=3840) {
            b.process(chunks.data()+offset,std::min(size_t(3840),chunks.size()-offset),2,rate);
        }
        assert(whole == chunks);
    }
    { // Invalid settings do not replace the current target or damage buffers.
        RemoteAudioGain gain;
        assert(!gain.setDb(-1)); assert(!gain.setDb(61));
        assert(!gain.setDb(std::numeric_limits<float>::infinity()));
        assert(!gain.setDb(std::numeric_limits<float>::quiet_NaN()));
        auto bytes=constant(10,1000,-1000); const auto original=bytes;
        process(gain,bytes); assert(bytes==original);
        gain.setDb(12);
        gain.process(bytes.data(),bytes.size(),0,rate);
        gain.process(bytes.data(),bytes.size(),2,0);
        gain.process(nullptr,bytes.size(),2,rate);
        assert(bytes==original);
    }
}
