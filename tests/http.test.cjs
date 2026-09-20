const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createBinaryUploader } = require('../server/http.js');

async function fixture(t, handler) {
  const server = http.createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return createBinaryUploader((url, options, cb) => http.request({ hostname: '127.0.0.1', port: server.address().port, path: url.pathname, ...options }, cb));
}

const destination = 'https://upload.bckt.io/v1/upload?token=test';
const run = (upload, body, headers = {}, method = 'POST', timeout = 1000, url = destination) => new Promise(resolve => upload(method, url, body.toString('hex'), headers, timeout, (status, raw, responseHeaders) => resolve({ status, raw, headers: responseHeaders })));

test('server transport sends every byte including nulls and non-UTF8 over HTTP', async t => {
  const expected = Buffer.from(Array.from({ length: 203394 }, (_, i) => i % 256));
  let received;
  const upload = await fixture(t, (req, res) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      received = { body: Buffer.concat(chunks), headers: req.headers, method: req.method };
      res.writeHead(201, { 'content-type': 'application/json' });
      res.end('{"success":true}');
    });
  });
  const result = await run(upload, expected, { 'Content-Length': String(expected.length), 'Content-Type': 'image/png', Authorization: 'must-not-send' }, 'PUT');
  assert.equal(result.status, 201);
  assert.deepEqual(received.body, expected);
  assert.equal(received.headers['content-length'], String(expected.length));
  assert.equal(received.headers.authorization, undefined);
  assert.equal(received.method, 'PUT');
});

test('invalid destinations and mismatched ticket sizes never reach the network', async () => {
  const upload = createBinaryUploader(() => { throw new Error('network must not run'); });
  for (const url of ['http://upload.bckt.io/v1/upload', 'https://upload.bckt.io.evil.test/v1/upload', 'https://user@upload.bckt.io/v1/upload', 'https://upload.bckt.io/other']) {
    assert.equal(JSON.parse((await run(upload, Buffer.from('x'), {}, 'POST', 1000, url)).raw).error.code, 'INVALID_UPLOAD_HOST');
  }
  assert.equal(JSON.parse((await run(upload, Buffer.from('x'), { 'Content-Length': '2' })).raw).error.code, 'CONTENT_LENGTH_MISMATCH');
});

test('redirects are returned without forwarding bytes to another destination', async t => {
  let requests = 0;
  const upload = await fixture(t, (req, res) => {
    requests++;
    req.resume();
    res.writeHead(302, { location: 'https://example.test/secret' });
    res.end();
  });
  assert.equal((await run(upload, Buffer.from('x'))).status, 302);
  assert.equal(requests, 1);
});

test('HTTP errors keep their response body and stalled uploads time out', async t => {
  const upload = await fixture(t, (req, res) => {
    req.resume();
    if (req.headers['x-file-name'] === 'stall') return;
    res.writeHead(400);
    res.end('{"error":{"code":"BAD_UPLOAD","message":"invalid file"}}');
  });
  const result = await run(upload, Buffer.from('x'));
  assert.equal(result.status, 400);
  assert.equal(JSON.parse(result.raw).error.code, 'BAD_UPLOAD');
  const timedOut = await run(upload, Buffer.from('x'), { 'X-File-Name': 'stall' }, 'POST', 30);
  assert.equal(JSON.parse(timedOut.raw).error.code, 'TIMEOUT');
});
