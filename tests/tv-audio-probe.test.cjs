// Node 24+: node --test tests/tv-audio-probe.test.cjs
// Execute the real ArkTS service with a controlled AudioKit boundary, without hardware or sound.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');

const source = readFileSync(resolve(__dirname,
  '../tv/overlay/entry/src/main/ets/services/TvAudioProbe.ets'), 'utf8')
  .replace(/^import .* from '@kit.AudioKit';\s*$/m, '')
  .replace(/^export /gm, '');
const executable = stripTypeScriptTypes(source + '\nglobalThis.TvAudioProbe = TvAudioProbe;');

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function createProbe(createAudioRenderer) {
  const context = vm.createContext({
    audio: {
      AudioSamplingRate: { SAMPLE_RATE_48000: 48000 },
      AudioChannel: { CHANNEL_2: 2 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
      AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
      StreamUsage: { STREAM_USAGE_MUSIC: 1 },
      createAudioRenderer,
    },
  });
  vm.runInContext(executable, context);
  return new context.TvAudioProbe();
}

function createRenderer(maxWriteBytes = Infinity) {
  return {
    chunks: [], started: 0, drained: 0, stopped: 0, released: 0,
    async start() { this.started++; },
    async write(buffer) {
      const count = Math.min(maxWriteBytes, buffer.byteLength);
      this.chunks.push(Buffer.from(new Uint8Array(buffer)).subarray(0, count));
      return count;
    },
    async drain() { this.drained++; },
    async stop() { this.stopped++; },
    async release() { this.released++; },
  };
}

test('probe plays 1.5 seconds of bounded, faded stereo PCM with the remote format', async () => {
  const renderer = createRenderer();
  let options;
  const probe = createProbe(async config => { options = config; return renderer; });
  assert.equal(await probe.play(), 'completed');
  assert.deepEqual(JSON.parse(JSON.stringify(options)), {
    streamInfo: { samplingRate: 48000, channels: 2, sampleFormat: 1, encodingType: 0 },
    rendererInfo: { usage: 1, rendererFlags: 0 },
  });
  const pcm = Buffer.concat(renderer.chunks);
  assert.equal(pcm.length, 48000 * 1.5 * 4);
  let peak = 0;
  for (let offset = 0; offset < pcm.length; offset += 4) {
    const left = pcm.readInt16LE(offset);
    assert.equal(left, pcm.readInt16LE(offset + 2));
    peak = Math.max(peak, Math.abs(left));
  }
  assert(peak > 4000 && peak <= Math.ceil(32767 * 0.15));
  assert.equal(pcm.readInt16LE(0), 0);
  assert.equal(pcm.readInt16LE(pcm.length - 4), 0);
  assert.equal(renderer.drained, 1);
  assert.equal(renderer.released, 1);
});

test('partial writes preserve every sample without duplication or truncation', async () => {
  const complete = createRenderer();
  const partial = createRenderer(400);
  assert.equal(await createProbe(async () => complete).play(), 'completed');
  assert.equal(await createProbe(async () => partial).play(), 'completed');
  assert(Buffer.concat(partial.chunks).equals(Buffer.concat(complete.chunks)));
  assert(partial.chunks.length > complete.chunks.length);
  assert.equal(partial.released, 1);
});

test('repeated play cannot overlap players and a finished probe can run again', async () => {
  const renderers = [];
  const probe = createProbe(async () => {
    const renderer = createRenderer();
    renderers.push(renderer);
    return renderer;
  });
  const first = probe.play();
  assert.equal(await probe.play(), 'busy');
  assert.equal(await first, 'completed');
  assert.equal(renderers.length, 1);
  assert.equal(await probe.play(), 'completed');
  assert.equal(renderers.length, 2);
  assert(renderers.every(renderer => renderer.released === 1));
});

test('cancellation during creation releases the late renderer without playing', { timeout: 3000 }, async () => {
  const creation = deferred();
  const renderer = createRenderer();
  const probe = createProbe(() => creation.promise);
  const playing = probe.play();
  probe.cancel();
  creation.resolve(renderer);
  assert.equal(await playing, 'cancelled');
  assert.equal(renderer.started, 0);
  assert.equal(renderer.chunks.length, 0);
  assert.equal(renderer.released, 1);
});

for (const phase of ['write', 'drain']) {
  test(`cancellation during ${phase} stops and releases exactly once`, { timeout: 3000 }, async () => {
    const entered = deferred();
    const pending = deferred();
    const renderer = createRenderer();
    renderer[phase] = () => { entered.resolve(); return pending.promise; };
    renderer.stop = async () => { renderer.stopped++; pending.resolve(0); };
    const probe = createProbe(async () => renderer);
    const playing = probe.play();
    await entered.promise;
    probe.cancel();
    probe.cancel();
    assert.equal(await playing, 'cancelled');
    assert.equal(renderer.stopped, 1);
    assert.equal(renderer.released, 1);
  });
}

test('invalid partial writes fail and release instead of spinning or replaying data', async () => {
  for (const invalidLength of [0, -1, 3, 3844]) {
    const renderer = createRenderer();
    renderer.write = async () => invalidLength;
    const probe = createProbe(async () => renderer);
    assert.equal(await probe.play(), 'failed');
    assert.equal(renderer.drained, 0);
    assert.equal(renderer.released, 1);
  }
});

test('start or drain failure still releases the renderer', async () => {
  for (const phase of ['start', 'drain']) {
    const renderer = createRenderer();
    renderer[phase] = async () => { throw new Error(`Failed ${phase}`); };
    assert.equal(await createProbe(async () => renderer).play(), 'failed');
    assert.equal(renderer.released, 1);
  }
});

test('creation failure clears busy state so playback can be retried', async () => {
  let attempts = 0;
  const renderer = createRenderer();
  const probe = createProbe(async () => {
    if (++attempts === 1) { throw new Error('Renderer unavailable'); }
    return renderer;
  });
  assert.equal(await probe.play(), 'failed');
  assert.equal(await probe.play(), 'completed');
  assert.equal(renderer.released, 1);
});
