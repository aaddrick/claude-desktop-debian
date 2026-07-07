// Protocol regression guard for the bwrap fallback daemon.
//
// Spawns cowork-vm-service.js on a private socket and drives it the way
// the official client does — 4-byte big-endian length-prefixed JSON —
// exercising the wire contract in PROTOCOL.md: one-shot requests,
// id-multiplexed pipe, subscribeEvents ack-then-events, the VM
// lifecycle, spawn stdout/exit events, and the methods added for the
// official helper protocol. Self-contained (spawns + reaps its own
// daemon) so it runs the same locally and in CI.
//
// Usage: node protocol-smoke.js   (exit 0 = all checks passed)
'use strict';
const net = require('net');
const os = require('os');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

const DAEMON = path.join(__dirname, '..', 'cowork-vm-service.js');
const SOCK = path.join(os.tmpdir(),
    `cowork-proto-smoke-${process.pid}.sock`);

function frame(obj) {
    const body = Buffer.from(JSON.stringify(obj), 'utf8');
    const len = Buffer.alloc(4);
    len.writeUInt32BE(body.length, 0);
    return Buffer.concat([len, body]);
}
function deframe(buf) {
    if (buf.length < 4) return null;
    const n = buf.readUInt32BE(0);
    if (buf.length < 4 + n) return null;
    return {
        msg: JSON.parse(buf.subarray(4, 4 + n).toString('utf8')),
        rest: Buffer.from(buf.subarray(4 + n)),
    };
}

let failures = 0;
function check(name, cond, extra) {
    process.stdout.write(`${cond ? 'ok' : 'FAIL'} - ${name}` +
        `${cond ? '' : ' ' + JSON.stringify(extra)}\n`);
    if (!cond) failures++;
}

function oneShot(payload) {
    return new Promise((resolve, reject) => {
        const s = net.createConnection(SOCK);
        let buf = Buffer.alloc(0);
        s.on('data', (d) => {
            buf = Buffer.concat([buf, d]);
            const r = deframe(buf);
            if (r) { s.end(); resolve(r.msg); }
        });
        s.on('error', reject);
        s.setTimeout(5000, () => { s.destroy(); reject(new Error('timeout')); });
        s.on('connect', () => s.write(frame(payload)));
    });
}

function waitForSocket(ms) {
    const deadline = Date.now() + ms;
    return new Promise((resolve, reject) => {
        (function poll() {
            if (fs.existsSync(SOCK)) return resolve();
            if (Date.now() > deadline) return reject(new Error('no socket'));
            setTimeout(poll, 100);
        })();
    });
}

async function main() {
    try { fs.unlinkSync(SOCK); } catch (_) {}
    const daemon = spawn(process.execPath, [DAEMON, '-socket', SOCK], {
        env: { ...process.env, COWORK_VM_BACKEND: 'host' },
        stdio: ['ignore', 'ignore', 'inherit'],
    });
    const stop = () => { try { daemon.kill('SIGKILL'); } catch (_) {} };

    try {
        await waitForSocket(6000);

        // one-shot, no id
        let r = await oneShot({ method: 'isRunning' });
        check('one-shot isRunning envelope', r.success === true && r.result
            && r.result.running === false && r.id === undefined, r);

        // persistent pipe: three id-tagged requests, matched by id
        const pipe = net.createConnection(SOCK);
        let pbuf = Buffer.alloc(0);
        const responses = new Map();
        let pipeDone;
        const pipeWait = new Promise((res) => { pipeDone = res; });
        pipe.on('data', (d) => {
            pbuf = Buffer.concat([pbuf, d]);
            let x;
            while ((x = deframe(pbuf)) !== null) {
                pbuf = x.rest;
                responses.set(x.msg.id, x.msg);
                if (responses.size === 3) pipeDone();
            }
        });
        await new Promise((res) => pipe.on('connect', res));
        pipe.write(frame({ method: 'configure', id: 1,
            params: { userDataName: 'smoke', sessionOnly: true } }));
        pipe.write(frame({ method: 'getSessionsDiskInfo', id: 2,
            params: { lowWaterBytes: 0 } }));
        pipe.write(frame({ method: 'getNetworkDrives', id: 3 }));
        await Promise.race([pipeWait, new Promise((_, rej) =>
            setTimeout(() => rej(new Error('pipe timeout')), 5000))]);
        check('pipe: 3 id-matched responses', responses.size === 3,
            [...responses.keys()]);
        check('pipe: configure ok', responses.get(1).success === true,
            responses.get(1));
        const disk = responses.get(2);
        check('getSessionsDiskInfo shape', disk.success === true
            && typeof disk.result.totalBytes === 'number'
            && typeof disk.result.freeBytes === 'number'
            && Array.isArray(disk.result.sessions), disk);
        check('getNetworkDrives shape', responses.get(3).success === true
            && Array.isArray(responses.get(3).result.drives),
            responses.get(3));
        pipe.end();

        // event subscription: ack first, then events
        const sub = net.createConnection(SOCK);
        let sbuf = Buffer.alloc(0);
        const frames = [];
        sub.on('data', (d) => {
            sbuf = Buffer.concat([sbuf, d]);
            let x;
            while ((x = deframe(sbuf)) !== null) { sbuf = x.rest; frames.push(x.msg); }
        });
        await new Promise((res) => sub.on('connect', res));
        sub.write(frame({ method: 'subscribeEvents',
            params: { userDataName: 'smoke' } }));
        await new Promise((res) => setTimeout(res, 300));
        check('subscribeEvents ack first', frames.length >= 1
            && frames[0].success === true, frames[0]);

        // startVM -> guest connects (polled, as the client does)
        r = await oneShot({ method: 'startVM',
            params: { bundlePath: '/nonexistent' } });
        check('startVM success', r.success === true, r);
        let connected = false;
        for (let i = 0; i < 20 && !connected; i++) {
            r = await oneShot({ method: 'isGuestConnected' });
            connected = r.success === true && r.result.connected === true;
            if (!connected) await new Promise((res) => setTimeout(res, 200));
        }
        check('isGuestConnected after startVM (polled)', connected, r);

        // spawn a real process; expect stdout + exit events
        r = await oneShot({ method: 'spawn', params: {
            id: 'smoke-1', name: 'smoke', command: '/bin/echo',
            args: ['hello-proto'], isResume: false, oauthToken: 'tok',
        } });
        check('spawn success', r.success === true, r);
        await new Promise((res) => setTimeout(res, 800));
        const stdout = frames.find((f) => f.type === 'stdout'
            && f.id === 'smoke-1');
        const exit = frames.find((f) => f.type === 'exit' && f.id === 'smoke-1');
        check('stdout event received', !!stdout
            && stdout.data.includes('hello-proto'), frames.slice(1));
        check('exit event received', !!exit && exit.exitCode === 0, exit);

        // added methods respond with their documented shapes
        r = await oneShot({ method: 'pruneSessionCaches',
            params: { onlyIfFreeBytesBelow: 1, includeSessionTmp: false } });
        check('pruneSessionCaches shape', r.success === true
            && Array.isArray(r.result.prunedSessions), r);
        r = await oneShot({ method: 'sendGuestResponse',
            params: { id: 99, resultJson: '{}' } });
        check('sendGuestResponse accepted', r.success === true, r);
        r = await oneShot({ method: 'deleteSessionDirs',
            params: { names: ['x'] } });
        check('deleteSessionDirs shape', r.success === true
            && Array.isArray(r.result.deleted), r);

        // unknown method -> success:false
        r = await oneShot({ method: 'noSuchMethod' });
        check('unknown method rejected', r.success === false
            && /Unknown method/.test(r.error), r);

        sub.end();
    } catch (e) {
        process.stderr.write('fatal: ' + (e && e.stack || e) + '\n');
        failures++;
    } finally {
        stop();
        try { fs.unlinkSync(SOCK); } catch (_) {}
    }

    process.stdout.write(failures === 0 ? 'ALL PASS\n'
        : `${failures} FAILURES\n`);
    process.exit(failures === 0 ? 0 : 1);
}
main();
