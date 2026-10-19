// AIX platform override, preloaded with `node -r` by the AIX launchers.
//
// VS Code's server only has code paths for linux / darwin / win32. On AIX the
// safest behaviour is to look like Linux to the components that branch on
// process.platform at startup (the server itself, the pty host, deviceid),
// while leaving everything else (Node internals, extensions) seeing 'aix'.
//
// The decision is made per call from the stack trace, which is cheap enough
// for the handful of call sites that run at startup.
'use strict';
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
