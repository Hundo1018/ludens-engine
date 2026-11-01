// Recording: the canvas (captureStream) plus, when the audio graph is running, the AudioWorklet output,
// muxed into one WebM by MediaRecorder. WebCodecs would need a hand-written muxer; MediaRecorder muxes natively.
export interface Recording { blob: Blob; mime: string; seconds: number; video: boolean; audio: boolean }

const MIMES = ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm;codecs=av01,opus", "video/webm"];

export async function record(
  canvas: HTMLCanvasElement, seconds: number, audio?: { ctx: AudioContext; node: AudioNode },
): Promise<Recording> {
  const stream = canvas.captureStream(60);
  let sink: MediaStreamAudioDestinationNode | null = null;
  if (audio) {
    sink = audio.ctx.createMediaStreamDestination();
    audio.node.connect(sink);
    for (const t of sink.stream.getAudioTracks()) stream.addTrack(t);
  }
  const mime = MIMES.find((m) => MediaRecorder.isTypeSupported(m));
  if (!mime) throw new Error("MediaRecorder supports none of " + MIMES.join(", "));
  const rec = new MediaRecorder(stream, { mimeType: mime });
  const chunks: Blob[] = [];
  rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  const stopped = new Promise<void>((res) => { rec.onstop = () => res(); });
  const t0 = performance.now();
  rec.start(250);
  await new Promise((r) => setTimeout(r, seconds * 1000));
  rec.stop();
  await stopped;
  for (const t of stream.getTracks()) t.stop();
  if (sink) audio!.node.disconnect(sink);
  return {
    blob: new Blob(chunks, { type: mime }), mime, seconds: (performance.now() - t0) / 1000,
    video: stream.getVideoTracks().length > 0, audio: sink !== null,
  };
}
