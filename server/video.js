const fs = require('node:fs/promises');
const path = require('node:path');
const { randomBytes } = require('node:crypto');
const { createBinaryUploader } = require(typeof GetResourcePath === 'function'
  ? path.join(GetResourcePath(GetCurrentResourceName()), 'server', 'http.js') : './http.js');

const ok = data => ({ success: true, status: 200, data });
const fail = (code, message, uncertain = false) => ({ success: false, status: 0, error: { code, message, uncertain } });
const terminal = task => Boolean(task.result);

async function openVideo(rootPath, filename, maximum) {
  if (typeof filename !== 'string' || !rootPath) throw new Error('INVALID_CAPTURE_FILE');
  const root = await fs.realpath(rootPath);
  const temp = path.join(root, 'tmp');
  if (await fs.realpath(temp) !== temp) throw new Error('INVALID_CAPTURE_FILE');
  const target = path.resolve(filename);
  if (path.dirname(target) !== temp || !/^[\w-]{24}\.webm$/.test(path.basename(target))) throw new Error('INVALID_CAPTURE_FILE');
  const info = await fs.lstat(target);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('INVALID_CAPTURE_FILE');
  const handle = await fs.open(target, 'r');
  try {
    const current = await handle.stat();
    if (current.dev !== info.dev || current.ino !== info.ino) throw new Error('INVALID_CAPTURE_FILE');
    const header = Buffer.alloc(4);
    await handle.read(header, 0, 4, 0);
    const error = current.size < 4 ? 'EMPTY_CAPTURE' : current.size > maximum ? 'CAPTURE_TOO_LARGE'
      : header.toString('hex') !== '1a45dfa3' ? 'INVALID_VIDEO' : null;
    return {
      handle, size: current.size, error,
      async cleanup() {
        await handle.close();
        try {
          if (await fs.realpath(temp) !== temp) return false;
          const latest = await fs.lstat(target);
          if (!latest.isFile() || latest.isSymbolicLink() || latest.dev !== info.dev || latest.ino !== info.ino) return false;
          await fs.unlink(target);
          return true;
        } catch (error) { return error.code === 'ENOENT'; }
      },
    };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

function createVideoManager({ provider, resourcePath, uploader = createBinaryUploader(), notify = () => {}, now = Date.now }) {
  const tasks = new Map();
  const historyMs = 10 * 60 * 1000;

  function prune() {
    const completed = [...tasks.values()].filter(terminal);
    for (const task of completed) {
      if (now() - task.finishedAt > historyMs || tasks.size >= 128) tasks.delete(task.id);
    }
  }
  function snapshot(task) {
    return { capture_id: task.id, player: task.player, state: task.state, active: !terminal(task), started_at: task.startedAt, ...(task.result ? { result: task.result } : {}) };
  }
  function finish(task, result, state = result.success ? 'completed' : 'failed') {
    if (terminal(task)) return;
    clearTimeout(task.stopTimer);
    clearTimeout(task.deadline);
    task.state = state;
    task.result = result;
    task.finishedAt = now();
    for (const cb of task.waiters.splice(0)) { try { cb(result); } catch {} }
    try { notify(task.owner, task.id, result); } catch {}
    prune();
  }
  function owned(owner, id) {
    prune();
    const task = tasks.get(id);
    return task && task.owner === owner ? task : null;
  }
  function stop(task) {
    if (terminal(task) || !['recording', 'stopping'].includes(task.state)) return;
    provider.stopVideoCapture(task.providerId);
    task.state = 'stopping';
  }
  function cancel(task, code = 'CAPTURE_CANCELLED', message = 'The video capture was cancelled.') {
    if (terminal(task)) return;
    const uncertain = task.state === 'uploading' || task.state === 'verifying';
    try { stop(task); } catch {}
    finish(task, fail(code, message, uncertain), 'cancelled');
    if (task.abortUpload) task.abortUpload();
  }
  function bridge(task, operation, payload) {
    return new Promise(resolve => {
      const timer = setTimeout(() => resolve(fail('TIMEOUT', 'The video API request timed out.', operation === 'verify')), task.options.uploadTimeoutMs);
      try {
        task.authorize(operation, payload, result => {
          clearTimeout(timer);
          resolve(result);
        });
      } catch {
        clearTimeout(timer);
        resolve(fail('VIDEO_API_FAILED', 'The video API request could not be completed.', operation === 'verify'));
      }
    });
  }
  async function captured(task, outcome) {
    if (task.received) return;
    task.received = true;
    let file;
    let result;
    try {
      if (!outcome || outcome.status !== 'success' || outcome.captureId !== task.providerId || Number(outcome.source) !== task.player) {
        result = fail('VIDEO_CAPTURE_FAILED', 'screencapture could not complete the recording.');
        return;
      }
      file = await openVideo(resourcePath(), outcome.filePath, task.options.maxBytes);
      if (terminal(task)) return;
      clearTimeout(task.stopTimer);
      if (file.error) {
        result = fail(file.error, file.error === 'CAPTURE_TOO_LARGE' ? 'The video exceeds the configured upload limit.' : 'The recording is empty or is not a WebM file.');
        return;
      }
      task.state = 'authorizing';
      const metadata = { filename: task.filename, size: file.size, folder: task.options.folder, content_type: 'video/webm', private: task.options.private };
      const ticket = await bridge(task, 'authorize', metadata);
      if (terminal(task)) return;
      if (!ticket || !ticket.success) {
        result = ticket || fail('UPLOAD_AUTHORIZATION_FAILED', 'The upload could not be authorized.');
        return;
      }
      const data = ticket.data;
      if (!data || !['POST', 'PUT'].includes(data.method) || !Number.isFinite(Date.parse(data.expires_at)) || Date.parse(data.expires_at) <= now()) {
        result = fail('INVALID_UPLOAD_TICKET', 'The upload ticket is invalid or expired.');
        return;
      }
      task.state = 'uploading';
      const response = await new Promise(resolve => {
        const stream = file.handle.createReadStream({ start: 0, end: file.size - 1, autoClose: false });
        task.abortUpload = uploader.stream(data.method, data.upload_url, stream, file.size, data.headers, task.options.uploadTimeoutMs,
          (status, raw, headers) => resolve({ status, raw, headers }));
      });
      task.abortUpload = null;
      if (terminal(task)) return;
      let payload;
      try { payload = JSON.parse(response.raw); } catch {}
      if (response.status >= 200 && response.status < 300 && payload?.success !== false && typeof payload?.file_key === 'string') {
        task.state = 'verifying';
        const verified = await bridge(task, 'verify', { ...metadata, file_key: payload.file_key });
        if (terminal(task)) return;
        result = verified?.success ? { success: true, status: response.status, data: { ...verified.data, capture_id: task.id, duration: Number(outcome.duration) || task.options.duration, filename: task.filename } }
          : verified || fail('UPLOAD_UNVERIFIED', 'The uploaded video could not be verified.', true);
      } else {
        result = {
          success: false, status: response.status,
          error: { code: payload?.error?.code || 'VIDEO_UPLOAD_FAILED', message: payload?.error?.message || 'The video upload failed.', uncertain: response.status === 0 || response.status >= 500 || (response.status >= 200 && response.status < 300) },
          ...(typeof payload?.request_id === 'string' ? { request_id: payload.request_id } : {}),
        };
      }
    } catch {
      result = fail('CAPTURE_FILE_ERROR', 'The temporary recording could not be safely opened or uploaded.', task.state === 'uploading');
    } finally {
      if (file) {
        let removed = false;
        try { removed = await file.cleanup(); } catch {}
        if (!removed && (result || task.result)) (result || task.result).temp_cleanup_failed = true;
      }
      if (result) finish(task, result);
    }
  }
  return {
    start(owner, player, options, authorizeUpload) {
      prune();
      const active = [...tasks.values()].filter(task => !terminal(task));
      if (active.some(task => task.player === player)) return fail('CAPTURE_IN_PROGRESS', 'This player already has a pending video.');
      if (active.length >= options.maxCaptures) return fail('CAPTURE_QUEUE_FULL', 'Too many videos are pending.');
      const id = randomBytes(12).toString('hex');
      const task = { id, owner, player, options, authorize: authorizeUpload, filename: options.filename || `capture-${id}.webm`, state: 'recording', startedAt: now(), waiters: [] };
      tasks.set(id, task);
      try {
        task.providerId = provider.startVideoCapture(player, { duration: options.duration, maxWidth: options.maxWidth, maxHeight: options.maxHeight }, outcome => {
          queueMicrotask(() => { void captured(task, outcome); });
        });
        if (typeof task.providerId !== 'string' || !task.providerId) {
          finish(task, fail('CAPTURE_UNAVAILABLE', 'screencapture did not start the recording. Check for an active recording or live stream.'));
          return task.result;
        }
        task.stopTimer = setTimeout(() => {
          try { stop(task); } catch { cancel(task, 'CAPTURE_STOP_FAILED', 'The recording could not be stopped.'); }
        }, options.duration * 1000);
        task.deadline = setTimeout(() => cancel(task, 'CAPTURE_TIMEOUT', 'The video capture timed out. A started upload may still complete.'), options.duration * 1000 + options.finishTimeoutMs + options.uploadTimeoutMs);
        return ok(snapshot(task));
      } catch {
        finish(task, fail('CAPTURE_UNAVAILABLE', 'Install and start a screencapture build with video exports.'));
        return task.result;
      }
    },
    status(owner, id) {
      const task = owned(owner, id);
      return task ? ok(snapshot(task)) : fail('CAPTURE_NOT_FOUND', 'No video capture belongs to this resource with that id.');
    },
    wait(owner, id, callback) {
      const task = owned(owner, id);
      if (!task) return callback(fail('CAPTURE_NOT_FOUND', 'No video capture belongs to this resource with that id.'));
      if (terminal(task)) return callback(task.result);
      if (task.waiters.length >= 32) return callback(fail('QUEUE_FULL', 'Too many callers are waiting for this video.'));
      task.waiters.push(callback);
    },
    stop(owner, id) {
      const task = owned(owner, id);
      if (!task) return fail('CAPTURE_NOT_FOUND', 'No video capture belongs to this resource with that id.');
      try { stop(task); } catch { return fail('CAPTURE_STOP_FAILED', 'The recording could not be stopped.'); }
      return ok(snapshot(task));
    },
    cancel(owner, id) {
      const task = owned(owner, id);
      if (!task) return fail('CAPTURE_NOT_FOUND', 'No video capture belongs to this resource with that id.');
      cancel(task);
      return ok(snapshot(task));
    },
    drop(player) {
      for (const task of tasks.values()) if (task.player === player) cancel(task, 'PLAYER_DISCONNECTED', 'The player disconnected.');
    },
    release(owner) {
      for (const task of tasks.values()) if (!owner || task.owner === owner) cancel(task, 'RESOURCE_STOPPED', 'The capture resource stopped.');
    },
  };
}

module.exports = { createVideoManager, openVideo };

if (typeof GetCurrentResourceName === 'function') {
  const resource = GetCurrentResourceName();
  const manager = createVideoManager({
    provider: {
      startVideoCapture: (...args) => global.exports.screencapture.startVideoCapture(...args),
      stopVideoCapture: id => global.exports.screencapture.stopVideoCapture(id),
    },
    resourcePath: () => GetResourcePath('screencapture'),
    notify: (owner, id, result) => emit('bckt:videoFinished', owner, id, {
      success: result.success, status: result.status, ...(result.error ? { code: result.error.code } : {}),
    }),
  });
  global.exports('_video', (operation, owner, argument, options, authorize, callback) => {
    if (GetInvokingResource() !== resource) return callback(fail('RESOURCE_FORBIDDEN', 'Internal video transport.'));
    if (operation === 'start') return callback(manager.start(owner, argument, options, authorize));
    if (operation === 'wait') return manager.wait(owner, argument, callback);
    if (['status', 'stop', 'cancel'].includes(operation)) return callback(manager[operation](owner, argument));
    callback(fail('INVALID_ARGUMENT', 'Unknown video operation.'));
  });
  on('playerDropped', () => manager.drop(Number(global.source)));
  on('onResourceStop', name => manager.release(name === resource || name === 'screencapture' ? null : name));
}
