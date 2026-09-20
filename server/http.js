const https = require('node:https');

function createBinaryUploader(request = https.request) {
  const active = new Set();
  function upload(method, destination, hex, ticketHeaders, timeout, callback) {
    let finished = false;
    let req;
    let timer;
    const finish = (status, body, headers = {}) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      active.delete(cancel);
      callback(status, body, headers);
    };
    const fail = (code, message, uncertain = false) => finish(0, JSON.stringify({ error: { code, message, uncertain } }));
    const cancel = () => {
      fail('TRANSPORT_ERROR', 'The upload connection was closed.', true);
      if (req) req.destroy();
    };
    try {
      const url = new URL(destination);
      if (url.protocol !== 'https:' || url.hostname !== 'upload.bckt.io' || url.port || url.username || url.password || url.pathname !== '/v1/upload' || url.hash) {
        fail('INVALID_UPLOAD_HOST', 'Unexpected upload destination.');
        return;
      }
      if (!['POST', 'PUT'].includes(method) || typeof hex !== 'string' || !hex.length || hex.length > 196 * 1024 * 1024 || hex.length % 2 || /[^0-9a-f]/i.test(hex)) {
        fail('INVALID_ARGUMENT', 'Invalid binary upload request.');
        return;
      }
      const body = Buffer.from(hex, 'hex');
      const headers = {};
      for (const [name, value] of Object.entries(ticketHeaders || {})) {
        const lower = name.toLowerCase();
        if (lower === 'content-length' && Number(value) !== body.length) {
          fail('CONTENT_LENGTH_MISMATCH', 'The upload ticket size does not match the file bytes.');
          return;
        }
        if (['content-type', 'x-file-name', 'x-file-name-encoding'].includes(lower)) headers[lower] = String(value);
      }
      headers['content-length'] = String(body.length);
      active.add(cancel);
      timer = setTimeout(() => {
        fail('TIMEOUT', 'The upload timed out. Its outcome may be unknown.', true);
        if (req) req.destroy();
      }, Math.max(1, Math.min(Number(timeout) || 30000, 300000)));
      req = request(url, { method, headers }, res => {
        const chunks = [];
        let size = 0;
        res.on('data', chunk => {
          size += chunk.length;
          if (size > 1024 * 1024) {
            fail('INVALID_RESPONSE', 'The upload response exceeded the size limit.', true);
            res.destroy();
            req.destroy();
          } else chunks.push(chunk);
        });
        res.on('end', () => finish(res.statusCode, Buffer.concat(chunks).toString('utf8'), res.headers));
        res.on('error', cancel);
        res.on('aborted', cancel);
      });
      req.on('error', cancel);
      req.end(body);
    } catch {
      fail('TRANSPORT_ERROR', 'The upload request could not be completed.', Boolean(req));
      if (req) req.destroy();
    }
  }
  upload.close = () => { for (const cancel of [...active]) cancel(); };
  return upload;
}

module.exports = { createBinaryUploader };

if (typeof GetCurrentResourceName === 'function') {
  const resource = GetCurrentResourceName();
  const upload = createBinaryUploader();
  global.exports('_uploadBytes', (method, url, hex, headers, timeout, callback) => {
    if (GetInvokingResource() !== resource) {
      callback(0, JSON.stringify({ error: { code: 'RESOURCE_FORBIDDEN', message: 'Internal upload transport.' } }), {});
      return;
    }
    upload(method, url, hex, headers, timeout, callback);
  });
  on('onResourceStop', name => { if (name === resource) upload.close(); });
}
