const images = new Map();
const controllers = new Map();
const resource = GetParentResourceName();
const post = (name, data) => fetch(`https://${resource}/${name}`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data)
});

function decodeImage(uri, maxBytes = 8 * 1024 * 1024) {
  if (typeof uri !== 'string' || uri.length > maxBytes * 1.4 + 200) throw new Error('Image is too large.');
  const match = /^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=]+)$/.exec(uri);
  if (!match) throw new Error('Expected a PNG, JPEG or WebP data URI.');
  const binary = atob(match[2]);
  if (!binary.length || binary.length > maxBytes) throw new Error('Invalid image size.');
  return new Blob([Uint8Array.from(binary, c => c.charCodeAt(0))], { type: match[1] });
}

async function upload(id, ticket, blob) {
  const url = new URL(ticket.upload_url);
  if (url.origin !== 'https://upload.bckt.io' || url.pathname !== '/v1/upload' || url.username || url.password || ticket.method !== 'POST') throw new Error('Invalid upload destination.');
  const expiration = Date.parse(ticket.expires_at);
  if (Number(ticket.max_bytes) !== blob.size || !Number.isFinite(expiration) || expiration <= Date.now()) throw new Error('Upload ticket is expired or does not match the image.');
  const headers = {};
  for (const [name, value] of Object.entries(ticket.headers || {})) {
    if (['content-type', 'x-file-name', 'x-file-name-encoding'].includes(name.toLowerCase())) headers[name] = value;
  }
  const filenameHeader = Object.keys(headers).find(name => name.toLowerCase() === 'x-file-name');
  const encodingHeader = Object.keys(headers).find(name => name.toLowerCase() === 'x-file-name-encoding');
  if (filenameHeader && !encodingHeader) {
    headers[filenameHeader] = encodeURIComponent(headers[filenameHeader]);
    headers['X-File-Name-Encoding'] = 'uri-component';
  }
  const controller = new AbortController();
  controllers.set(id, controller);
  const timer = setTimeout(() => controller.abort(), 110000);
  try {
    const response = await fetch(url, { method: 'POST', headers, body: blob, signal: controller.signal, credentials: 'omit', redirect: 'error' });
    const result = await response.json();
    if (!response.ok || result.success !== true) {
      const error = new Error(result.error?.message || 'Upload failed.');
      error.code = result.error?.code || 'UPLOAD_FAILED';
      error.status = response.status;
      throw error;
    }
    return { success: true, status: response.status, data: result };
  } finally {
    clearTimeout(timer);
    controllers.delete(id);
  }
}

window.addEventListener('message', async ({ data: message }) => {
  if (!message || typeof message.id !== 'string') return;
  const { action, id } = message;
  try {
    if (action === 'cancel') {
      images.delete(id);
      controllers.get(id)?.abort();
    } else if (action === 'capture') {
      const blob = decodeImage(message.data, message.maxBytes);
      images.set(id, blob);
      await post('captureSize', { id, size: blob.size });
    } else if (action === 'ticket') {
      const blob = images.get(id);
      if (!blob) throw new Error('Screenshot is no longer available.');
      images.delete(id);
      const result = await upload(id, message.ticket, blob);
      await post('captureFinished', { id, receipt: { file_key: result.data.file_key } });
    } else if (action === 'direct') {
      await post('directStarted', { id });
      const result = await upload(id, message.ticket, decodeImage(message.data));
      await post('directFinished', { id, result });
    }
  } catch (error) {
    images.delete(id);
    if (action === 'direct') {
      await post('directFinished', { id, result: { success: false, status: error.status || 0, error: { code: error.code || 'UPLOAD_FAILED', message: error.message, uncertain: !error.status || error.status >= 500 } } }).catch(() => {});
    } else if (action !== 'cancel') {
      await post('captureFailed', { id }).catch(() => {});
    }
  }
});
