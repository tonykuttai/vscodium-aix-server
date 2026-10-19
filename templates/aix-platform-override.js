// AIX runtime shim for the VSCodium server. Preloaded into every Node process
// of the server (main server, extension host, pty host, file watcher, remote
// CLI) through NODE_OPTIONS=--require set in bin/aix-env.sh, and also with
// `-r` by the launchers.
//
// It does two things, both only inside VS Code's own processes:
//
// 1. process.platform spoofing. VS Code only has code paths for linux /
//    darwin / win32. The components that branch on process.platform at
//    startup (the server itself, the pty host, deviceid) are told 'linux';
//    everything else (Node internals, extensions) still sees 'aix'. The
//    decision is per call from the stack trace, which is cheap enough for the
//    handful of call sites that run at startup.
//
// 2. fs.watch() without AHAFS. libuv implements fs.watch on AIX with the
//    kernel's AHAFS (/aha) event filesystem. AHAFS has a finite monitor pool
//    shared by all users and, once wedged, blocks every process that touches
//    it in an unkillable state until root remounts /aha or reboots (incident
//    on cpap8104, 2026-10-19, see notes/AIX-WATCHERS-AND-BINARIES.md). The
//    server must therefore never call into it. fs.watch and fs.promises.watch
//    are replaced with a stat-polling implementation that keeps the FSWatcher
//    contract VS Code relies on (non-recursive dir and file watches; recursive
//    watching is reported unsupported so VS Code uses @parcel/watcher, which
//    we build with a polling backend).
//
// Environment:
//   VSCODIUM_AIX_FSWATCH=off          keep Node's native fs.watch (debugging)
//   VSCODIUM_AIX_FSWATCH=force        apply the shim in any process (tests)
//   VSCODIUM_AIX_FSWATCH_INTERVAL_MS  poll interval, default 1000, min 250
'use strict';

if (!global.__vscodiumAixShim) {
    global.__vscodiumAixShim = true;
    installShim();
}

function installShim() {
    const fs = require('fs');
    const path = require('path');
    const EventEmitter = require('events');

    const mode = (process.env.VSCODIUM_AIX_FSWATCH || '').toLowerCase();
    const script = process.argv[1] || '';
    const isVsCodeProcess =
        /server-main\.js$|server-cli\.js$|bootstrap-fork(\.js)?$/.test(script) ||
        process.argv.some(a => /^--type=(extensionHost|ptyHost|fileWatcher|utilityProcess|shared-process)/.test(a));

    if (!isVsCodeProcess && mode !== 'force') {
        // Not ours (for example a user's `node` in an integrated terminal):
        // change nothing, and stop the preload from propagating further.
        stripSelfFromNodeOptions();
        return;
    }

    //-----------------------------------------------------------------------
    // 1. process.platform
    //-----------------------------------------------------------------------
    const realPlatform = process.platform;
    const spoofIf = ['ptyHost', 'server-main', 'server-cli', 'deviceid'];
    Object.defineProperty(process, 'platform', {
        configurable: true,
        enumerable: true,
        get() {
            const stack = new Error().stack || '';
            for (const marker of spoofIf) {
                if (stack.includes(marker)) {
                    return 'linux';
                }
            }
            return realPlatform;
        }
    });

    //-----------------------------------------------------------------------
    // 2. fs.watch polling
    //-----------------------------------------------------------------------
    if (mode === 'off') {
        return;
    }

    const intervalMs = Math.max(250, parseInt(process.env.VSCODIUM_AIX_FSWATCH_INTERVAL_MS || '', 10) || 1000);

    function toPath(filename) {
        if (Buffer.isBuffer(filename)) { return filename.toString(); }
        if (filename instanceof URL) { return require('url').fileURLToPath(filename); }
        if (typeof filename !== 'string') {
            const err = new TypeError('The "filename" argument must be of type string, Buffer, or URL');
            err.code = 'ERR_INVALID_ARG_TYPE';
            throw err;
        }
        return filename;
    }

    function unsupportedRecursive() {
        const err = new Error('Recursive watch is not supported on this platform (AIX shim)');
        err.code = 'ERR_FEATURE_UNAVAILABLE_ON_PLATFORM';
        return err;
    }

    // Snapshot of a directory: name -> "mtimeMs:size:ino:type"; of a file:
    // { '': signature }.
    function signature(st) {
        return `${st.mtimeMs}:${st.size}:${st.ino}:${st.isDirectory() ? 'd' : 'f'}`;
    }

    class PollingFSWatcher extends EventEmitter {
        constructor(target, options, listener) {
            super();
            this._target = target;
            this._encoding = options.encoding || 'utf8';
            this._closed = false;
            if (typeof listener === 'function') {
                this.on('change', listener);
            }
            // Like native fs.watch: a missing path is a synchronous error.
            const st = fs.statSync(target);
            this._isDir = st.isDirectory();
            this._snapshot = this._scan();
            this._timer = setInterval(() => this._tick(), intervalMs);
            if (options.persistent === false) { this._timer.unref(); }
            if (options.signal) {
                if (options.signal.aborted) { this.close(); }
                else { options.signal.addEventListener('abort', () => this.close(), { once: true }); }
            }
        }

        _scan() {
            const snap = new Map();
            if (this._isDir) {
                let names;
                try { names = fs.readdirSync(this._target); } catch (e) { throw e; }
                for (const name of names) {
                    try { snap.set(name, signature(fs.lstatSync(path.join(this._target, name)))); }
                    catch (e) { /* vanished between readdir and stat */ }
                }
            } else {
                snap.set('', signature(fs.statSync(this._target)));
            }
            return snap;
        }

        _name(name) {
            const n = this._isDir ? name : path.basename(this._target);
            return this._encoding === 'buffer' ? Buffer.from(n) : n;
        }

        _tick() {
            if (this._closed) { return; }
            let now;
            try {
                now = this._scan();
            } catch (e) {
                if (e && e.code === 'ENOENT') {
                    // Watched path disappeared: native fs.watch reports 'rename'
                    // and keeps the watcher alive. Keep polling for a return.
                    if (this._snapshot.size > 0) {
                        this._snapshot = new Map();
                        this.emit('change', 'rename', this._name(''));
                    }
                    return;
                }
                this.emit('error', e);
                return;
            }
            const prev = this._snapshot;
            this._snapshot = now;
            if (this._isDir) {
                for (const [name, sig] of now) {
                    const old = prev.get(name);
                    if (old === undefined) { this.emit('change', 'rename', this._name(name)); }
                    else if (old !== sig) { this.emit('change', 'change', this._name(name)); }
                }
                for (const name of prev.keys()) {
                    if (!now.has(name)) { this.emit('change', 'rename', this._name(name)); }
                }
            } else {
                const old = prev.get('');
                const sig = now.get('');
                if (old === undefined) { this.emit('change', 'rename', this._name('')); }
                else if (old !== sig) {
                    // inode change = replaced (rename), otherwise modified.
                    const type = old.split(':')[2] !== sig.split(':')[2] ? 'rename' : 'change';
                    this.emit('change', type, this._name(''));
                }
            }
        }

        close() {
            if (this._closed) { return; }
            this._closed = true;
            clearInterval(this._timer);
            process.nextTick(() => this.emit('close'));
        }

        ref() { if (this._timer) { this._timer.ref(); } return this; }
        unref() { if (this._timer) { this._timer.unref(); } return this; }
    }

    function normalizeOptions(options, listener) {
        if (typeof options === 'function') { listener = options; options = {}; }
        else if (typeof options === 'string') { options = { encoding: options }; }
        else if (options == null) { options = {}; }
        return [options, listener];
    }

    fs.watch = function watch(filename, options, listener) {
        const target = toPath(filename);
        [options, listener] = normalizeOptions(options, listener);
        if (options.recursive) { throw unsupportedRecursive(); }
        return new PollingFSWatcher(target, options, listener);
    };

    if (fs.promises) {
        fs.promises.watch = function watch(filename, options) {
            const target = toPath(filename);
            [options] = normalizeOptions(options, undefined);
            if (options.recursive) { throw unsupportedRecursive(); }
            const signal = options.signal;
            return {
                [Symbol.asyncIterator]() {
                    const queue = [];
                    let pending = null;      // { resolve, reject } of an awaiting next()
                    let finished = false;
                    let failure = null;
                    let watcher;
                    const settle = () => {
                        if (!pending) { return; }
                        const p = pending; pending = null;
                        if (queue.length) { p.resolve({ value: queue.shift(), done: false }); }
                        else if (failure) { p.reject(failure); }
                        else if (finished) { p.resolve({ value: undefined, done: true }); }
                        else { pending = p; }
                    };
                    const stop = (err) => {
                        if (finished) { return; }
                        finished = true;
                        failure = err || null;
                        if (watcher) { watcher.close(); }
                        settle();
                    };
                    try {
                        watcher = new PollingFSWatcher(target, options, undefined);
                    } catch (e) {
                        failure = e; finished = true;
                    }
                    if (watcher) {
                        watcher.on('change', (eventType, name) => { queue.push({ eventType, filename: name }); settle(); });
                        watcher.on('error', (e) => stop(e));
                        if (signal) {
                            const abort = () => {
                                const e = new Error('The operation was aborted');
                                e.name = 'AbortError'; e.code = 'ABORT_ERR';
                                stop(e);
                            };
                            if (signal.aborted) { abort(); }
                            else { signal.addEventListener('abort', abort, { once: true }); }
                        }
                    }
                    return {
                        next() {
                            return new Promise((resolve, reject) => { pending = { resolve, reject }; settle(); });
                        },
                        return() {
                            stop(null);
                            return Promise.resolve({ value: undefined, done: true });
                        },
                        [Symbol.asyncIterator]() { return this; }
                    };
                }
            };
        };
    }

    function stripSelfFromNodeOptions() {
        const opts = process.env.NODE_OPTIONS;
        if (!opts || !opts.includes('aix-platform-override.js')) { return; }
        const cleaned = opts.replace(/(^|\s)(--require|-r)(=|\s+)"?[^"\s]*aix-platform-override\.js"?/g, ' ').trim();
        if (cleaned) { process.env.NODE_OPTIONS = cleaned; } else { delete process.env.NODE_OPTIONS; }
    }
}
