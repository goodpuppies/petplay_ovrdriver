/** Connects to an already-running native actor. Owns the connection, never the process. */
export type NativeProxyOptions = {
  path: string;
  encode: (value: unknown) => string;
  decode: (value: string) => unknown;
};
type Addressed = {
  address: { fm: string; to: string };
  type: string;
  payload?: unknown;
};
export class NativeUnixProxy extends EventTarget implements Worker {
  onmessage: ((this: Worker, event: MessageEvent) => unknown) | null = null;
  onmessageerror: ((this: Worker, event: MessageEvent) => unknown) | null =
    null;
  onerror: ((this: Worker, event: ErrorEvent) => unknown) | null = null;
  private readonly writer: WritableStreamDefaultWriter<Uint8Array>;
  private readonly encoder = new TextEncoder();
  private queuedBytes = 0;
  private writes = Promise.resolve();
  private ended = false;
  private readonly pending = new Map<string, Addressed>();
  private constructor(
    readonly actorId: string,
    private readonly conn: Deno.UnixConn,
    private readonly reader: ReadableStreamDefaultReader<Uint8Array>,
    private buffered: Uint8Array,
    private readonly options: NativeProxyOptions,
  ) {
    super();
    this.writer = conn.writable.getWriter();
    void this.read().catch((error) => this.end(String(error), true));
  }
  static async connect(options: NativeProxyOptions): Promise<NativeUnixProxy> {
    const conn = await Deno.connect({ transport: "unix", path: options.path });
    const reader = conn.readable.getReader();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const hello = (async () => {
        let buffered = new Uint8Array(0);
        for (;;) {
          const { value, done } = await reader.read();
          if (done) {
            throw new Error("Native actor closed before announcing identity");
          }
          buffered = combine(buffered, value);
          const end = buffered.indexOf(10);
          if (end >= 0) {
            if (end > 16384) {
              throw new Error("Native actor announcement too large");
            }
            const packet = options.decode(
              new TextDecoder().decode(buffered.subarray(0, end)),
            ) as {
              kind?: string;
              actorId?: string;
              protocol?: number;
              ownership?: string;
            };
            if (
              packet.kind !== "ready" || packet.protocol !== 1 ||
              packet.ownership !== "external" ||
              typeof packet.actorId !== "string" ||
              !/^[^@]+@[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
                .test(packet.actorId)
            ) {
              throw new Error("Invalid native actor identity announcement");
            }
            return new NativeUnixProxy(
              packet.actorId,
              conn,
              reader,
              buffered.slice(end + 1),
              options,
            );
          }
          if (buffered.length > 16384) {
            throw new Error("Native actor announcement too large");
          }
        }
      })();
      return await Promise.race([
        hello,
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error("Native actor handshake timed out")),
            3000,
          );
        }),
      ]);
    } catch (error) {
      conn.close();
      throw error;
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }
  postMessage(
    raw: unknown,
    transfer?: Transferable[] | StructuredSerializeOptions,
  ) {
    if (this.ended) {
      throw new DOMException("Native proxy disconnected", "InvalidStateError");
    }
    const transfers = Array.isArray(transfer) ? transfer : transfer?.transfer;
    if (transfers?.length) {
      throw new DOMException(
        "Native proxy does not support transferables",
        "DataCloneError",
      );
    }
    const message = raw as Addressed;
    if (message.address?.to !== this.actorId) {
      throw new Error("Proxy target does not match remote actor identity");
    }
    if (message.type.split(":")[0] === "INIT") {
      throw new Error(
        "Cannot initialize an externally owned actor through its proxy",
      );
    }
    const bytes = this.encoder.encode(
      this.options.encode({ kind: "message", data: message }) + "\n",
    );
    if (bytes.length > 16385) {
      throw new DOMException(
        "Native packet exceeds 16384 bytes",
        "DataCloneError",
      );
    }
    if (this.queuedBytes + bytes.length > 65536) {
      throw new DOMException("Native proxy backpressure", "QuotaExceededError");
    }
    if (message.type.includes(":")) this.pending.set(message.type, message);
    this.queuedBytes += bytes.length;
    this.writes = this.writes.then(async () => {
      if (this.ended) return;
      await this.writer.write(bytes);
      this.queuedBytes -= bytes.length;
    }).catch((error) => this.end(String(error), true));
  }
  terminate() {
    this.end("Native proxy detached", false);
  }
  private async read() {
    for (;;) {
      for (;;) {
        const end = this.buffered.indexOf(10);
        if (end < 0) break;
        if (end > 16384) throw new Error("Native packet exceeds 16384 bytes");
        const line = this.buffered.slice(0, end);
        this.buffered = this.buffered.slice(end + 1);
        const packet = this.options.decode(new TextDecoder().decode(line)) as {
          kind: string;
          data?: Addressed;
          message?: string;
        };
        if (
          packet.kind !== "message" || !packet.data ||
          packet.data.address.fm !== this.actorId
        ) {
          throw new Error(packet.message ?? "Invalid native actor response");
        }
        this.pending.delete(packet.data.type);
        this.emit(packet.data);
      }
      if (this.buffered.length > 16384) {
        throw new Error("Native packet exceeds 16384 bytes");
      }
      const { done, value } = await this.reader.read();
      if (done) {
        this.end("Native actor transport closed", !this.ended);
        return;
      }
      this.buffered = combine(this.buffered, value);
    }
  }
  private emit(data: Addressed) {
    const event = new MessageEvent("message", { data });
    this.onmessage?.call(this, event);
    this.dispatchEvent(event);
  }
  private end(message: string, reportError: boolean) {
    if (this.ended) return;
    this.ended = true;
    for (const request of this.pending.values()) {
      this.emit({
        address: { fm: this.actorId, to: request.address.fm },
        type: request.type,
        payload: {
          __actorError: {
            message,
            event: "transport-closed",
            type: request.type.split(":")[0],
          },
        },
      });
    }
    this.pending.clear();
    try {
      this.conn.close();
    } catch { /* peer may already have closed */ }
    if (reportError) {
      const event = new ErrorEvent("error", {
        message,
        error: new Error(message),
      });
      this.onerror?.call(this, event);
      this.dispatchEvent(event);
    }
  }
}
function combine(a: Uint8Array, b: Uint8Array) {
  const result = new Uint8Array(a.length + b.length);
  result.set(a);
  result.set(b, a.length);
  return result;
}
