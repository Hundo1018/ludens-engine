// Recording: the canvas (captureStream) plus, when the audio graph is running, the AudioWorklet output,
// muxed into one WebM by MediaRecorder. WebCodecs would need a hand-written muxer; MediaRecorder muxes natively.
export interface Recording { blob: Blob; mime: string; seconds: number; video: boolean; audio: boolean }

const MIMES_AV = ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm;codecs=av01,opus"];
const MIMES_V = ["video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm;codecs=av01"];

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
  const mimes = [...(sink ? MIMES_AV : MIMES_V), "video/webm"];
  const mime = mimes.find((m) => MediaRecorder.isTypeSupported(m));
  if (!mime) throw new Error("MediaRecorder supports none of " + mimes.join(", "));
  const rec = new MediaRecorder(stream, { mimeType: mime });
  const chunks: Blob[] = [];
  const trace: any = ((window as any).__rec = { mime, chunks: 0, state: "new", error: "" });
  rec.ondataavailable = (e) => { trace.chunks++; if (e.data.size) chunks.push(e.data); };
  rec.onerror = (e: any) => { trace.error = String(e.error ?? e.type); };
  const stopped = new Promise<void>((res) => { rec.onstop = () => res(); });
  const t0 = performance.now();
  rec.start(250);
  trace.state = "started";
  await new Promise((r) => setTimeout(r, seconds * 1000));
  trace.state = "stopping";
  rec.stop();
  await Promise.race([stopped, new Promise((_, rej) => setTimeout(() => rej(new Error("MediaRecorder never stopped (chunks " + trace.chunks + ")")), 10000))]);
  trace.state = "stopped";
  for (const t of stream.getTracks()) t.stop();
  if (sink) audio!.node.disconnect(sink);
  return {
    blob: new Blob(chunks, { type: mime }), mime, seconds: (performance.now() - t0) / 1000,
    video: stream.getVideoTracks().length > 0, audio: sink !== null,
  };
}
