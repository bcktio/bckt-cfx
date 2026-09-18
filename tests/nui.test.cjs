const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
function harness() {
  const requests = [];
  let listener;
  const context = vm.createContext({
    Blob, Uint8Array, URL, AbortController, atob, setTimeout, clearTimeout, console,
    GetParentResourceName: () => 'bckt',
    window: { addEventListener: (_, fn) => { listener = fn; } },
    fetch: async (url, options) => {
      if (!String(url).endsWith('/directStarted')) requests.push({ url: String(url), ...options });
      return { ok: true, status: 201, json: async () => ({ success: true, file_key: 'test' }) };
    }
  });
  vm.runInContext(fs.readFileSync('web/main.js', 'utf8'), context);
  return { requests, send: data => listener({ data }) };
}
const ticket = {
  upload_url: 'https://upload.bckt.io/v1/upload?token=test', method: 'POST', max_bytes: 3,
  expires_at: new Date(Date.now() + 60000).toISOString(),
  headers: { 'Content-Type': 'image/png', 'Content-Length': '3', Authorization: 'must-not-forward' }
};
test('direct image upload sends a Blob and omits forbidden headers', async () => {
  const h = harness();
  await h.send({ action: 'direct', id: '1', ticket, data: 'data:image/png;base64,YWJj' });
  assert.equal(h.requests.length, 2);
  assert.equal(h.requests[0].body.size, 3);
  assert.equal(h.requests[0].headers.Authorization, undefined);
  assert.equal(h.requests[0].headers['Content-Length'], undefined);
  assert.equal(JSON.parse(h.requests[1].body).result.success, true);
});
test('foreign destinations are rejected before upload', async () => {
  const h = harness();
  await h.send({ action: 'direct', id: '2', ticket: { ...ticket, upload_url: 'https://evil.test/' }, data: 'data:image/png;base64,YWJj' });
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].url, 'https://bckt/directFinished');
  assert.equal(JSON.parse(h.requests[0].body).result.success, false);
});
test('ticket size and expiration are enforced', async () => {
  for (const invalid of [{ ...ticket, max_bytes: 4 }, { ...ticket, expires_at: '2000-01-01T00:00:00Z' }, { ...ticket, expires_at: 'invalid' }]) {
    const h = harness();
    await h.send({ action: 'direct', id: '3', ticket: invalid, data: 'data:image/png;base64,YWJj' });
    assert.equal(h.requests.length, 1);
    assert.equal(JSON.parse(h.requests[0].body).result.success, false);
  }
});
test('unicode filenames are encoded for HTTP headers', async () => {
  const h = harness();
  await h.send({ action: 'direct', id: '5', ticket: { ...ticket, headers: { 'X-File-Name': '写真.png', 'Content-Type': 'image/png' } }, data: 'data:image/png;base64,YWJj' });
  assert.equal(h.requests[0].headers['X-File-Name'], encodeURIComponent('写真.png'));
  assert.equal(h.requests[0].headers['X-File-Name-Encoding'], 'uri-component');
});
test('capture waits for server authorization before sending bytes', async () => {
  const h = harness();
  await h.send({ action: 'capture', id: '4', data: 'data:image/png;base64,YWJj', maxBytes: 100 });
  assert.equal(h.requests.length, 1);
  assert.equal(h.requests[0].url, 'https://bckt/captureSize');
  assert.equal(JSON.parse(h.requests[0].body).size, 3);
  await h.send({ action: 'ticket', id: '4', ticket });
  assert.equal(h.requests[1].url, ticket.upload_url);
  assert.equal(h.requests[2].url, 'https://bckt/captureFinished');
});
