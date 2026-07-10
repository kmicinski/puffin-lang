// wasi-shim.js -- the browser host for puffin-vm.wasm (docs/WASM-VM.md §3.5).
//
// STATUS: scaffold, UNRUN (no puffin-vm.wasm exists yet -- the wasm
// build is gated on installing wasi-sdk; see src/vm/Makefile `wasm`).
// This is the ~300-line purpose-built WASI preview1 host the runtime
// actually reaches -- NOT a general polyfill. It implements exactly
// the syscalls core.c + lib/*.c touch (fd_write/fd_read for
// stdout/stderr/stdin, path_open + fd_read/fd_write against an
// in-memory FS seeded from the module file map, proc_exit,
// clock_time_get, args) and returns ENOSYS loudly for the rest, so a
// missing dependency surfaces as an error instead of silent wrong
// output.
//
// It also supplies the non-WASI `puffin.abort` import that
// wasm-host.c's __wrap_exit calls (§3.4): it throws PuffinAbort, which
// the engine catches to unwind wasm frames and reset VM execution
// state while keeping the heap/globals/symbols alive.

// ---- WASI preview1 errno constants (subset) ----
const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOENT = 44;
const ERRNO_NOSYS = 52; // ENOSYS

// clock ids
const CLOCKID_REALTIME = 0;

// fd_prestat / preopen: fd 3 is the single preopened directory "/".
const PREOPEN_FD = 3;
const FIRST_USER_FD = 4;

// path_open oflags
const OFLAGS_CREAT = 1 << 0;
const OFLAGS_TRUNC = 1 << 3;

// Thrown by proc_exit and by the puffin.abort import; the engine
// catches it to end a run/eval without tearing down the instance.
export class PuffinAbort extends Error {
  constructor(code) {
    super(`puffin abort (code ${code})`);
    this.name = 'PuffinAbort';
    this.code = code;
  }
}

const enc = new TextEncoder();
const dec = new TextDecoder();

// The shim owns: linear memory (bound after instantiate), an stdin
// byte buffer with a read cursor, an onOutput sink for fd 1/2, and an
// in-memory FS (path -> Uint8Array) seeded from the module file map,
// plus an open-file table for fds >= FIRST_USER_FD.
export class WasiShim {
  // opts: { stdin: Uint8Array, onOutput: (str)=>void, files: {path:string|Uint8Array}, args: string[],
  //         onStderr: (str)=>void   -- optional; default: merged into onOutput,
  //         onReplResult: (str)=>void -- REPL sessions (docs/WASM-VM.md §5.2):
  //           one rendered string per non-void top-level form, delivered by
  //           the VM's RESULT opcode through the puffin.repl_result import }
  constructor({ stdin = new Uint8Array(0), onOutput = () => {}, files = {}, args = [], onStderr = null, onReplResult = () => {} } = {}) {
    this.onOutput = onOutput;
    this.onStderr = onStderr;
    this.onReplResult = onReplResult;
    this.stdin = stdin;
    this.stdinPos = 0;
    this.args = ['puffin-vm', ...args];
    this.memory = null; // set by bindMemory after instantiate
    this.view = null;

    // in-memory FS: absolute path -> Uint8Array
    this.fs = new Map();
    for (const [path, data] of Object.entries(files)) {
      const abs = path.startsWith('/') ? path : '/' + path;
      this.fs.set(abs, typeof data === 'string' ? enc.encode(data) : data);
    }
    // open-file table: fd -> { path, pos, append, writable, buf }
    this.open = new Map();
    this.nextFd = FIRST_USER_FD;
  }

  bindMemory(memory) {
    this.memory = memory;
    this.view = new DataView(memory.buffer);
  }

  // DataView can go stale after memory.grow; refresh lazily.
  dv() {
    if (this.view.buffer !== this.memory.buffer) this.view = new DataView(this.memory.buffer);
    return this.view;
  }
  u8() { return new Uint8Array(this.memory.buffer); }

  // Read an array of (buf, len) iovecs at `ptr` into one Uint8Array.
  readIovs(ptr, count) {
    const dv = this.dv();
    const chunks = [];
    let total = 0;
    for (let i = 0; i < count; i++) {
      const base = dv.getUint32(ptr + i * 8, true);
      const len = dv.getUint32(ptr + i * 8 + 4, true);
      chunks.push([base, len]);
      total += len;
    }
    return { chunks, total };
  }

  // The import object handed to WebAssembly.instantiate.
  imports() {
    const wasi = {
      // ---- args / environ ----
      args_sizes_get: (argcPtr, bufSizePtr) => {
        const dv = this.dv();
        let bufSize = 0;
        for (const a of this.args) bufSize += enc.encode(a).length + 1;
        dv.setUint32(argcPtr, this.args.length, true);
        dv.setUint32(bufSizePtr, bufSize, true);
        return ERRNO_SUCCESS;
      },
      args_get: (argvPtr, argvBufPtr) => {
        const dv = this.dv();
        const mem = this.u8();
        let p = argvBufPtr;
        for (let i = 0; i < this.args.length; i++) {
          dv.setUint32(argvPtr + i * 4, p, true);
          const bytes = enc.encode(this.args[i]);
          mem.set(bytes, p);
          mem[p + bytes.length] = 0;
          p += bytes.length + 1;
        }
        return ERRNO_SUCCESS;
      },
      environ_sizes_get: (cntPtr, bufSizePtr) => {
        const dv = this.dv();
        dv.setUint32(cntPtr, 0, true);
        dv.setUint32(bufSizePtr, 0, true);
        return ERRNO_SUCCESS;
      },
      environ_get: () => ERRNO_SUCCESS,

      // ---- clocks ----
      clock_time_get: (id, _precision, timePtr) => {
        const dv = this.dv();
        const nowNs = BigInt(Math.round((id === CLOCKID_REALTIME ? Date.now() : performance.now()) * 1e6));
        dv.setBigUint64(timePtr, nowNs, true);
        return ERRNO_SUCCESS;
      },

      // ---- stdout / stderr / stdin + file writes ----
      fd_write: (fd, iovsPtr, iovsLen, nwrittenPtr) => {
        const { chunks, total } = this.readIovs(iovsPtr, iovsLen);
        const mem = this.u8();
        if (fd === 1 || fd === 2) {
          // streamed synchronously; the run-worker's 8KB/50ms buffer
          // still handles flood control (§3.5). stderr goes to
          // onStderr when provided (the REPL session captures fatal
          // runtime errors there), else merges into onOutput.
          let s = '';
          for (const [base, len] of chunks) s += dec.decode(mem.subarray(base, base + len));
          if (fd === 2 && this.onStderr) this.onStderr(s);
          else this.onOutput(s);
        } else {
          const f = this.open.get(fd);
          if (!f || !f.writable) return ERRNO_BADF;
          for (const [base, len] of chunks) {
            const bytes = mem.subarray(base, base + len);
            f.buf = concat(f.buf, bytes, f.pos);
            f.pos += len;
          }
          this.fs.set(f.path, f.buf);
        }
        this.dv().setUint32(nwrittenPtr, total, true);
        return ERRNO_SUCCESS;
      },
      fd_read: (fd, iovsPtr, iovsLen, nreadPtr) => {
        const { chunks } = this.readIovs(iovsPtr, iovsLen);
        const mem = this.u8();
        let src, posRef;
        if (fd === 0) { src = this.stdin; posRef = this; }
        else {
          const f = this.open.get(fd);
          if (!f) return ERRNO_BADF;
          src = f.buf; posRef = f;
        }
        const posKey = fd === 0 ? 'stdinPos' : 'pos';
        let read = 0;
        for (const [base, len] of chunks) {
          const avail = src.length - posRef[posKey];
          if (avail <= 0) break;
          const n = Math.min(len, avail);
          mem.set(src.subarray(posRef[posKey], posRef[posKey] + n), base);
          posRef[posKey] += n;
          read += n;
          if (n < len) break;
        }
        this.dv().setUint32(nreadPtr, read, true);
        return ERRNO_SUCCESS;
      },
      fd_close: (fd) => { this.open.delete(fd); return ERRNO_SUCCESS; },
      fd_seek: (fd, offset, whence, newOffsetPtr) => {
        const f = this.open.get(fd);
        if (!f) return ERRNO_BADF;
        const off = Number(offset);
        if (whence === 0) f.pos = off;          // SET
        else if (whence === 1) f.pos += off;    // CUR
        else f.pos = f.buf.length + off;        // END
        this.dv().setBigUint64(newOffsetPtr, BigInt(f.pos), true);
        return ERRNO_SUCCESS;
      },
      fd_fdstat_get: (fd, statPtr) => {
        // filetype 4 = regular file, 3 = directory; minimal fields.
        const dv = this.dv();
        dv.setUint8(statPtr, fd === PREOPEN_FD ? 3 : 4);
        dv.setUint16(statPtr + 2, 0, true); // flags
        dv.setBigUint64(statPtr + 8, 0n, true);  // rights base
        dv.setBigUint64(statPtr + 16, 0n, true); // rights inheriting
        return ERRNO_SUCCESS;
      },
      fd_fdstat_set_flags: () => ERRNO_SUCCESS,

      // ---- preopens (the single "/" directory) ----
      fd_prestat_get: (fd, prestatPtr) => {
        if (fd !== PREOPEN_FD) return ERRNO_BADF;
        const dv = this.dv();
        dv.setUint8(prestatPtr, 0);              // tag: dir
        dv.setUint32(prestatPtr + 4, 1, true);   // name len ("/" = 1)
        return ERRNO_SUCCESS;
      },
      fd_prestat_dir_name: (fd, pathPtr, pathLen) => {
        if (fd !== PREOPEN_FD) return ERRNO_BADF;
        this.u8().set(enc.encode('/').subarray(0, pathLen), pathPtr);
        return ERRNO_SUCCESS;
      },

      // ---- path-based file ops against the in-memory FS ----
      path_open: (dirfd, _dirflags, pathPtr, pathLen, oflags, _rb, _ri, _fdflags, openedFdPtr) => {
        const name = dec.decode(this.u8().subarray(pathPtr, pathPtr + pathLen));
        const abs = name.startsWith('/') ? name : '/' + name;
        const writable = (oflags & (OFLAGS_CREAT | OFLAGS_TRUNC)) !== 0;
        let buf = this.fs.get(abs);
        if (buf === undefined) {
          if (!(oflags & OFLAGS_CREAT)) return ERRNO_NOENT;
          buf = new Uint8Array(0);
          this.fs.set(abs, buf);
        }
        if (oflags & OFLAGS_TRUNC) buf = new Uint8Array(0);
        const fd = this.nextFd++;
        this.open.set(fd, { path: abs, pos: 0, writable, buf });
        this.dv().setUint32(openedFdPtr, fd, true);
        return ERRNO_SUCCESS;
      },
      path_filestat_get: (_dirfd, _flags, pathPtr, pathLen, statPtr) => {
        const name = dec.decode(this.u8().subarray(pathPtr, pathPtr + pathLen));
        const abs = name.startsWith('/') ? name : '/' + name;
        const buf = this.fs.get(abs);
        if (buf === undefined) return ERRNO_NOENT;
        const dv = this.dv();
        for (let i = 0; i < 64; i++) dv.setUint8(statPtr + i, 0);
        dv.setUint8(statPtr + 16, 4); // filetype: regular file
        dv.setBigUint64(statPtr + 32, BigInt(buf.length), true); // size
        return ERRNO_SUCCESS;
      },

      // ---- process ----
      proc_exit: (code) => { throw new PuffinAbort(code); },

      // ---- misc, stubbed loudly ----
      random_get: (buf, len) => {
        const mem = this.u8().subarray(buf, buf + len);
        if (globalThis.crypto && globalThis.crypto.getRandomValues) globalThis.crypto.getRandomValues(mem);
        else for (let i = 0; i < len; i++) mem[i] = (Math.random() * 256) | 0;
        return ERRNO_SUCCESS;
      },
      sched_yield: () => ERRNO_SUCCESS,
      poll_oneoff: () => ERRNO_NOSYS,
    };

    // Any WASI import we did not implement returns ENOSYS rather than
    // trapping with an obscure "unknown import" instantiate error.
    const wasiProxy = new Proxy(wasi, {
      get: (target, name) =>
        name in target ? target[name]
          : (...args) => { console.warn(`wasi-shim: unimplemented ${String(name)}(${args.join(',')}) -> ENOSYS`); return ERRNO_NOSYS; },
    });

    return {
      wasi_snapshot_preview1: wasiProxy,
      puffin: {
        // §3.4: the host_abort import that __wrap_exit calls.
        abort: (code) => { throw new PuffinAbort(code); },
        // §5.2: RESULT opcode delivery -- the VM rendered the value
        // with its own value->string; the bytes land here.
        repl_result: (ptr, len) => {
          this.onReplResult(dec.decode(this.u8().subarray(ptr, ptr + len)));
        },
      },
    };
  }
}

// Grow-and-write helper for file writes at an arbitrary position.
function concat(buf, bytes, pos) {
  const end = pos + bytes.length;
  if (end <= buf.length) { const out = buf.slice(); out.set(bytes, pos); return out; }
  const out = new Uint8Array(end);
  out.set(buf, 0);
  out.set(bytes, pos);
  return out;
}
