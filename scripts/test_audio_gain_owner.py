"""Run the generated gain NAPI and lazy-player publication code with fake handles."""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--client', type=Path, default=root / '.work/client')
client = parser.parse_args().client
source = (client / 'entry/src/main/cpp/audio/audio_player.cpp').read_text()

def block(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

getter = block('static float RemoteAudioGainFor(', 'static Render::DecoderSessionIdentity OwnerForAudioHandle(')
install = block('static bool InstallSessionPlayer(', 'static void EnsureAudioSlot(')
setter = block('napi_value NapiSetRemoteAudioGain(', 'napi_value NapiPollAudioInterruptRecovery(')
assert 'player->SetRemoteGainDb(RemoteAudioGainFor(owner));' in source
assert 'remoteGain_.process(out, static_cast<size_t>(copied), channels_, sampleRate_);' in source

program = r'''
#include "matetv_remote_audio_gain.h"
#include <cassert>
#include <cstdint>
#include <initializer_list>
#include <limits>
#include <memory>
#include <mutex>
using napi_env = int;
struct Value { double number; bool boolean = false; };
using napi_value = Value*;
struct Request { Value gain, session; size_t argc = 2; };
using napi_callback_info = Request*;
constexpr int napi_ok = 0;
void napi_get_cb_info(napi_env, Request* request, size_t* argc, Value** args, void*, void*) {
    *argc = request->argc; args[0] = &request->gain; args[1] = &request->session;
}
void napi_get_boolean(napi_env, bool value, Value** result) {
    static Value yes {0,true}, no {0,false}; *result = value ? &yes : &no;
}
int napi_get_value_double(napi_env, Value* value, double* result) { *result=value->number; return 0; }
int napi_get_value_int64(napi_env, Value* value, int64_t* result) { *result=static_cast<int64_t>(value->number); return 0; }
namespace Render {
using DecoderSessionIdentity = int;
struct OwnerRegistry {
    int owner = 7;
    bool acquire(int requested) const { return owner > 0 && owner == requested; }
};
OwnerRegistry& SharedSessionSinkOwnerLease() { static OwnerRegistry registry; return registry; }
}
int OwnerFromSessionArg(napi_env, Value* session) { return static_cast<int>(session->number); }
struct AudioPlayer {
    float gain = 0;
    bool SetRemoteGainDb(float value) { gain=value; return true; }
};
struct ActiveAudioSlot {
    int owner = 7;
    std::shared_ptr<AudioPlayer> player;
    int64_t handle = 0;
    float remoteGainDb = 0;
} slot;
bool slotExists = true;
std::mutex g_activeAudioMutex;
ActiveAudioSlot* AudioSlotLocked(int owner) { return slotExists && owner == slot.owner ? &slot : nullptr; }
struct PlayerRegistry {
    std::shared_ptr<AudioPlayer> acquire(int64_t handle, int owner) {
        return handle > 0 && slotExists && owner == slot.owner && handle == slot.handle ? slot.player : nullptr;
    }
} g_audioRegistry;
GETTER
INSTALL
SETTER
bool set(double gain, int owner) {
    Request request {{gain},{static_cast<double>(owner)}};
    return NapiSetRemoteAudioGain(0,&request)->boolean;
}
int main() {
    assert(RemoteAudioGainFor(7)==0);
    assert(set(18,7)); assert(slot.remoteGainDb==18 && !slot.player);
    auto player=std::make_shared<AudioPlayer>();
    player->SetRemoteGainDb(RemoteAudioGainFor(7)); assert(player->gain==18);
    // A later setting arrives while lazy native Init is still in flight.
    assert(set(24,7)); assert(player->gain==18);
    assert(InstallSessionPlayer(7,player,10,0)); assert(player->gain==24);
    assert(set(60,7)); assert(player->gain==60 && slot.remoteGainDb==60);
    assert(set(9,7)); assert(player->gain==9 && slot.remoteGainDb==9);
    for (double invalid : {-1.,61.,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
        assert(!set(invalid,7)); assert(player->gain==9 && slot.remoteGainDb==9);
    }
    assert(!set(20,0)); assert(!set(20,8)); assert(player->gain==9);
    Render::SharedSessionSinkOwnerLease().owner=0;
    assert(!set(30,7)); assert(player->gain==9);
    slotExists=false; Render::SharedSessionSinkOwnerLease().owner=7;
    assert(!set(30,7)); assert(player->gain==9);
    // A distinct session starts at zero; neither an old owner nor its gain can leak over.
    slot=ActiveAudioSlot{}; slot.owner=8; slotExists=true; Render::SharedSessionSinkOwnerLease().owner=8;
    assert(RemoteAudioGainFor(8)==0); assert(!set(30,7)); assert(slot.remoteGainDb==0);
    auto next=std::make_shared<AudioPlayer>(); assert(InstallSessionPlayer(8,next,11,0)); assert(next->gain==0);
    auto stale=std::make_shared<AudioPlayer>(); assert(!InstallSessionPlayer(7,stale,12,0));
    assert(next->gain==0 && slot.handle==11);
}
'''.replace('GETTER', getter).replace('INSTALL', install).replace('SETTER', setter)
output = root / '.work/tv-audio-gain-owner-test.cpp'
output.write_text(program)
binary = output.with_suffix('')
subprocess.run(['c++', '-std=c++17', '-pthread',
    '-I' + str(root / 'tv/overlay/entry/src/main/cpp/audio'), str(output), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True, timeout=10)
print('Remote gain rejects stale owners and survives lazy initialization without crossing sessions.')
