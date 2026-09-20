const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { createVideoManager } = require('../server/video.js');
const { createBinaryUploader } = require('../server/http.js');

const defaults = { duration: 30, maxWidth: 1280, maxHeight: 720, maxBytes: 1024 * 1024, maxCaptures: 2, finishTimeoutMs: 1000, uploadTimeoutMs: 1000, folder: 'recordings', private: true };
const webm = Buffer.concat([Buffer.from('1a45dfa3', 'hex'), Buffer.from(Array.from({ length: 4096 }, (_, i) => i % 256))]);

async function fixture(t, overrides = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'bckt-video-'));
  await fs.mkdir(path.join(root, 'tmp'));
  const recordings = [];
  const stopped = [];
  const notices = [];
  const provider = {
    startVideoCapture(player, options, cb) {
      const id = `provider-${recordings.length}`;
      recordings.push({ id, player, options, cb });
      return id;
    },
    stopVideoCapture(id) { stopped.push(id); },
  };
  let sent = 0;
  const uploader = { stream(method, url, stream, size, headers, timeout, cb) {
    sent++;
    stream.resume();
    stream.on('end', () => cb(201, '{"success":true,"file_key":"uploaded-key"}', {}));
    return () => { stream.destroy(); cb(0, '{}', {}); };
  } };
  const manager = createVideoManager({ provider, resourcePath: () => root, uploader, notify: (...args) => notices.push(args), ...overrides });
  const bridgeCalls = [];
  const bridge = (operation, metadata, cb) => {
    bridgeCalls.push({ operation, metadata });
    cb(operation === 'authorize' ? { success: true, data: { method: 'POST', upload_url: 'https://upload.bckt.io/v1/upload?token=test', headers: { 'Content-Length': String(metadata.size) }, expires_at: new Date(Date.now() + 60000).toISOString() } }
      : { success: true, data: { file: { id: 'verified-id' }, url: 'https://cdn.bckt.io/signed', expires_at: 'later' } });
  };
  t.after(async () => {
    manager.release();
    assert.equal(path.dirname(root), os.tmpdir());
    await fs.rm(root, { recursive: true, force: true });
  });
  const complete = async (index = 0, bytes = webm) => {
    const record = recordings[index];
    const file = path.join(root, 'tmp', `${String(index).padStart(24, '0')}.webm`);
    await fs.writeFile(file, bytes);
    record.cb({ status: 'success', captureId: record.id, source: record.player, filePath: file, duration: 8 });
    return file;
  };
  const start = (owner = 'mdt', player = 1, options = {}, api = bridge) => manager.start(owner, player, { ...defaults, ...options }, api);
  const wait = (id, owner = 'mdt') => new Promise(resolve => manager.wait(owner, id, resolve));
  return { manager, root, start, wait, complete, recordings, stopped, notices, bridgeCalls, sent: () => sent };
}

test('video uploads authorize exact bytes, verify the catalog and delete the owned temporary file', async t => {
  let received;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      received = Buffer.concat(chunks);
      res.writeHead(201);
      res.end('{"success":true,"file_key":"uploaded-key"}');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const uploader = createBinaryUploader((url, options, cb) => http.request({ hostname: '127.0.0.1', port: server.address().port, path: url.pathname, ...options }, cb));
  const f = await fixture(t, { uploader });
  const started = f.start();
  assert.equal(started.success, true);
  const file = await f.complete();
  const result = await f.wait(started.data.capture_id);
  assert.equal(result.success, true);
  assert.deepEqual(received, webm);
  assert.equal(f.bridgeCalls[0].metadata.size, webm.length);
  assert.equal(f.bridgeCalls[0].metadata.private, true);
  assert.equal(f.bridgeCalls[1].metadata.file_key, 'uploaded-key');
  assert.equal(result.data.url, 'https://cdn.bckt.io/signed');
  await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  assert.equal(f.manager.status('mdt', started.data.capture_id).data.state, 'completed');
  assert.equal(f.notices.length, 1);
});

test('capture ownership, per-player exclusion, concurrency and manual stop are enforced', async t => {
  const f = await fixture(t);
  const id = f.start().data.capture_id;
  assert.equal(f.start().error.code, 'CAPTURE_IN_PROGRESS');
  assert.equal(f.manager.stop('other-resource', id).error.code, 'CAPTURE_NOT_FOUND');
  assert.equal((await f.wait(id, 'other-resource')).error.code, 'CAPTURE_NOT_FOUND');
  f.start('mdt', 2);
  assert.equal(f.start('mdt', 3).error.code, 'CAPTURE_QUEUE_FULL');
  assert.equal(f.manager.stop('mdt', id).data.state, 'stopping');
  assert.deepEqual(f.stopped, ['provider-0']);
  await f.complete();
  assert.equal((await f.wait(id)).success, true);
});

test('cancelled and disconnected captures reject waiters and clean up late recordings without uploading', async t => {
  const f = await fixture(t);
  const id = f.start().data.capture_id;
  const waiting = f.wait(id);
  f.manager.cancel('mdt', id);
  assert.equal((await waiting).error.code, 'CAPTURE_CANCELLED');
  const file = await f.complete();
  for (let i = 0; i < 50; i++) {
    if (!await fs.stat(file).catch(() => null)) break;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  assert.equal(f.sent(), 0);
  const next = f.start('mdt', 2).data.capture_id;
  f.manager.drop(2);
  assert.equal((await f.wait(next)).error.code, 'PLAYER_DISCONNECTED');
});

test('oversized, empty and invalid video files are removed before ticket creation', async t => {
  for (const [bytes, options, code] of [[webm, { maxBytes: 8 }, 'CAPTURE_TOO_LARGE'], [Buffer.alloc(0), {}, 'EMPTY_CAPTURE'], [Buffer.from('not a video'), {}, 'INVALID_VIDEO']]) {
    const f = await fixture(t);
    const id = f.start('mdt', 1, options).data.capture_id;
    const file = await f.complete(0, bytes);
    assert.equal((await f.wait(id)).error.code, code);
    assert.equal(f.bridgeCalls.length, 0);
    await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  }
});

test('provider paths outside its temporary directory are never uploaded or deleted', async t => {
  const f = await fixture(t);
  const id = f.start().data.capture_id;
  const external = path.join(f.root, 'keep.webm');
  await fs.writeFile(external, webm);
  f.recordings[0].cb({ status: 'success', captureId: 'provider-0', source: 1, filePath: external });
  assert.equal((await f.wait(id)).error.code, 'CAPTURE_FILE_ERROR');
  assert.deepEqual(await fs.readFile(external), webm);
  assert.equal(f.sent(), 0);
});

test('authorization failures and provider restarts settle pending operations', async t => {
  const f = await fixture(t);
  const id = f.start('mdt', 1, {}, (action, metadata, cb) => cb({ success: false, status: 403, error: { code: 'FORBIDDEN' } })).data.capture_id;
  const file = await f.complete();
  assert.equal((await f.wait(id)).error.code, 'FORBIDDEN');
  await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  const second = f.start('mdt', 2).data.capture_id;
  f.manager.release();
  assert.equal((await f.wait(second)).error.code, 'RESOURCE_STOPPED');
});

test('missing video exports fail immediately and synchronous callbacks are handled after the capture id', async t => {
  const missing = await fixture(t, { provider: {} });
  assert.equal(missing.start().error.code, 'CAPTURE_UNAVAILABLE');
  const immediate = await fixture(t, { provider: {
    startVideoCapture(player, options, cb) { cb({ status: 'error' }); return 'id'; },
    stopVideoCapture() {},
  } });
  const id = immediate.start().data.capture_id;
  assert.equal((await immediate.wait(id)).error.code, 'VIDEO_CAPTURE_FAILED');
});

test('server deadlines stop stalled recorders and resolve all waiters', async t => {
  const f = await fixture(t);
  const id = f.start('mdt', 1, { duration: 0.01, finishTimeoutMs: 10, uploadTimeoutMs: 10 }).data.capture_id;
  assert.equal((await f.wait(id)).error.code, 'CAPTURE_TIMEOUT');
  assert.ok(f.stopped.includes('provider-0'));
});

test('cancelling an in-flight upload aborts it once and reports an uncertain result', async t => {
  let ready;
  const uploading = new Promise(resolve => { ready = resolve; });
  let aborted = 0;
  const f = await fixture(t, { uploader: { stream(method, url, stream, size, headers, timeout, cb) {
    ready();
    return () => { aborted++; stream.destroy(); cb(0, '{}', {}); };
  } } });
  const id = f.start().data.capture_id;
  const file = await f.complete();
  await uploading;
  f.manager.cancel('mdt', id);
  f.manager.cancel('mdt', id);
  const result = await f.wait(id);
  assert.equal(result.error.uncertain, true);
  assert.equal(aborted, 1);
  for (let i = 0; i < 50; i++) {
    if (!await fs.stat(file).catch(() => null)) break;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  assert.equal(f.notices.length, 1);
});

test('expired tickets and upload failures clean up files without retries', async t => {
  const expired = await fixture(t);
  const expiredId = expired.start('mdt', 1, {}, (op, metadata, cb) => cb({ success: true, data: { method: 'POST', expires_at: '2020-01-01' } })).data.capture_id;
  const expiredFile = await expired.complete();
  assert.equal((await expired.wait(expiredId)).error.code, 'INVALID_UPLOAD_TICKET');
  assert.equal(expired.sent(), 0);
  await assert.rejects(fs.stat(expiredFile), { code: 'ENOENT' });
  let attempts = 0;
  const failed = await fixture(t, { uploader: { stream(method, url, stream, size, headers, timeout, cb) {
    attempts++;
    stream.destroy();
    cb(503, '{"error":{"code":"UNAVAILABLE","message":"try later"}}', {});
  } } });
  const id = failed.start().data.capture_id;
  const file = await failed.complete();
  const result = await failed.wait(id);
  assert.equal(result.error.code, 'UNAVAILABLE');
  assert.equal(result.error.uncertain, true);
  assert.equal(attempts, 1);
  await assert.rejects(fs.stat(file), { code: 'ENOENT' });
});
