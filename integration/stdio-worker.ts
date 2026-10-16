/** Standalone Zig actor transport for protocol tests. Not a launcher for vrserver.
 * The in-runtime driver will need an externally-owned connection transport.
 */
export function createStdioActorWorker(options: {
  executable: string;
  encode: (value: unknown) => string;
  decode: (value: string) => unknown;
}) {
  return class StdioActorWorker extends EventTarget implements Worker {
    onmessage: ((this: Worker, event: MessageEvent) => unknown) | null = null;
    onmessageerror: ((this: Worker, event: MessageEvent) => unknown) | null =
      null;
    onerror: ((this: Worker, event: ErrorEvent) => unknown) | null = null;
    private readonly child: Deno.ChildProcess;
    private readonly writer: WritableStreamDefaultWriter<Uint8Array>;
    private readonly encoder = new TextEncoder();
    private ready = false;
    private terminated = false;
    private closing = false;
    private pending: Uint8Array[] = [];
    private pendingBytes = 0;
    private writes = Promise.resolve();
    constructor(_url: string | URL, _workerOptions?: WorkerOptions) {
      super();
      this.child = new Deno.Command(options.executable, {
        stdin: "piped",
        stdout: "piped",
        stderr: "inherit",
      }).spawn();
      this.writer = this.child.stdin.getWriter();
      void this.read().catch((error) => this.fail(error));
      void this.child.status.then((status) => {
        if (!status.success && !this.terminated) {
          this.fail(new Error(`Native actor exited: ${status.code}`));
        }
      });
    }
    postMessage(
      message: unknown,
      transfer?: Transferable[] | StructuredSerializeOptions,
    ) {
      if (this.terminated) {
        throw new DOMException("Native actor terminated", "InvalidStateError");
      }
      const transfers = Array.isArray(transfer) ? transfer : transfer?.transfer;
      if (transfers?.length) {
        throw new DOMException(
          "Native actor does not support transferables",
          "DataCloneError",
        );
      }
      const bytes = this.encoder.encode(
        options.encode({ kind: "message", data: message }) + "\n",
      );
      if (bytes.length > 16385) {
        throw new DOMException(
          "Native actor packet exceeds 16384 bytes",
          "DataCloneError",
        );
      }
      const typ = (message as { type?: string }).type?.split(":")[0];
      if (typ === "SHUTDOWN_AND_CLOSE") this.closing = true;
      this.enqueue(bytes);
    }
    terminate() {
      if (this.terminated) return;
      this.terminated = true;
      this.pending = [];
      this.pendingBytes = 0;
      // This transport owns only the standalone test host. Never use it to kill vrserver.
      this.writes = this.writes.then(async () => {
        await this.writer.write(this.encoder.encode('{"kind":"terminate"}\n'));
        await this.writer.close();
      }).catch(() => {});
    }
    private enqueue(bytes: Uint8Array) {
      if (this.pendingBytes + bytes.length > 65536) {
        throw new DOMException(
          "Native actor transport backpressure",
          "QuotaExceededError",
        );
      }
      this.pendingBytes += bytes.length;
      if (!this.ready) this.pending.push(bytes);
      else this.write(bytes);
    }
    private write(bytes: Uint8Array) {
      this.writes = this.writes.then(async () => {
        await this.writer.write(bytes);
        this.pendingBytes -= bytes.length;
      }).catch((error) => this.fail(error));
    }
    private async read() {
      let buffered = "";
      for await (
        const chunk of this.child.stdout.pipeThrough(new TextDecoderStream())
      ) {
        buffered += chunk;
        for (;;) {
          const newline = buffered.indexOf("\n");
          if (newline < 0) break;
          const line = buffered.slice(0, newline);
          buffered = buffered.slice(newline + 1);
          const packet = options.decode(line) as {
            kind: string;
            data?: unknown;
            message?: string;
          };
          if (packet.kind === "ready") {
            this.ready = true;
            for (const bytes of this.pending.splice(0)) this.write(bytes);
          } else if (packet.kind === "message") {
            const event = new MessageEvent("message", { data: packet.data });
            this.onmessage?.call(this, event);
            this.dispatchEvent(event);
          } else if (packet.kind === "messageerror") {
            const event = new MessageEvent("messageerror", {
              data: packet.message,
            });
            this.onmessageerror?.call(this, event);
            this.dispatchEvent(event);
          } else throw new Error(`Unexpected native packet ${packet.kind}`);
        }
        if (buffered.length > 16384) {
          throw new Error("Native actor output exceeds packet limit");
        }
      }
      if (!this.closing && !this.terminated) {
        throw new Error("Native actor transport closed unexpectedly");
      }
    }
    private fail(error: unknown) {
      const event = new ErrorEvent("error", { message: String(error), error });
      this.onerror?.call(this, event);
      this.dispatchEvent(event);
    }
  };
}
