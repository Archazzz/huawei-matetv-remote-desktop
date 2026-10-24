import { audio } from '@kit.AudioKit';

export type TvAudioProbeResult = 'completed' | 'cancelled' | 'failed' | 'busy';

// A local playback baseline only: no microphone, remote audio or system volume changes.
export class TvAudioProbe {
  private generation: number = 0;
  private running: boolean = false;
  private renderer: audio.AudioRenderer | undefined = undefined;
  private stopping: Promise<void> | undefined = undefined;

  private tone(): ArrayBuffer {
    const sampleRate = 48000;
    const frameCount = sampleRate * 1.5;
    const pcm = new ArrayBuffer(frameCount * 4);
    const view = new DataView(pcm);
    const rampFrames = sampleRate * 0.08;
    for (let frame = 0; frame < frameCount; frame++) {
      const envelope = Math.min(1, frame / rampFrames, (frameCount - 1 - frame) / rampFrames);
      const time = frame / sampleRate;
      const wave = (Math.sin(2 * Math.PI * 440 * time) + Math.sin(2 * Math.PI * 660 * time)) * 0.075;
      const sample = Math.round(wave * envelope * 32767);
      view.setInt16(frame * 4, sample, true);
      view.setInt16(frame * 4 + 2, sample, true);
    }
    return pcm;
  }

  private stop(renderer: audio.AudioRenderer): Promise<void> {
    if (this.stopping === undefined) {
      this.stopping = renderer.stop().catch((): void => {});
    }
    return this.stopping;
  }

  cancel(): void {
    this.generation++;
    if (this.renderer !== undefined) {
      // Stop unblocks an outstanding write/drain. The play owner releases the renderer.
      this.stop(this.renderer);
    }
  }

  async play(): Promise<TvAudioProbeResult> {
    if (this.running) { return 'busy'; }
    this.running = true;
    const generation = ++this.generation;
    let renderer: audio.AudioRenderer | undefined = undefined;
    try {
      const options: audio.AudioRendererOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
          channels: audio.AudioChannel.CHANNEL_2,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 }
      };
      renderer = await audio.createAudioRenderer(options);
      if (generation !== this.generation) { return 'cancelled'; }
      this.renderer = renderer;
      await renderer.start();
      if (generation !== this.generation) { return 'cancelled'; }
      const pcm = this.tone();
      let offset = 0;
      // Small writes allow cancellation and handle partial writes without repeating samples.
      while (offset < pcm.byteLength && generation === this.generation) {
        const end = Math.min(offset + 3840, pcm.byteLength);
        const written = await renderer.write(pcm.slice(offset, end));
        if (written <= 0 || written > end - offset || written % 4 !== 0) {
          throw new Error('Invalid audio write length');
        }
        offset += written;
      }
      if (generation !== this.generation) { return 'cancelled'; }
      await renderer.drain();
      return generation === this.generation ? 'completed' : 'cancelled';
    } catch (_) {
      return generation === this.generation ? 'failed' : 'cancelled';
    } finally {
      if (renderer !== undefined) {
        await this.stop(renderer);
        try { await renderer.release(); } catch (_) {}
      }
      this.renderer = undefined;
      this.stopping = undefined;
      this.running = false;
    }
  }
}
