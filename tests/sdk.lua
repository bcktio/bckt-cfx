local exposed, events, timers, threads, calls = {}, {}, {}, {}, {}
local invoking = 'test-resource'
local nextStatus, nextBody = 200, { success = true }
local clientEvents, responseHandler = {}, nil
os.date = function() return '2026-09-18T12:00:00Z' end
local objects, token = {}, 0
json = {
    encode = function(value)
        token = token + 1
        local id = string.rep(' ', 100) .. tostring(token)
        objects[id] = value
        return id
    end,
    decode = function(value)
        if not objects[value] then error('invalid json') end
        return objects[value]
    end
}
exports = function(name, fn) exposed[name] = fn end
GetConvar = function() return 'bckt_test_key' end
GetInvokingResource = function() return invoking end
GetCurrentResourceName = function() return 'bckt' end
GetResourceState = function() return 'started' end
GetGameTimer = function() return 0 end
GetPlayerName = function(id) return id == 1 and 'test' or nil end
CreateThread = function(fn) threads[#threads + 1] = fn end
SetTimeout = function(_, fn) timers[#timers + 1] = fn end
Wait = function() end
TriggerEvent = function() end
TriggerClientEvent = function(name, player, id, value) clientEvents[#clientEvents + 1] = { name = name, player = player, id = id, value = value } end
RegisterNetEvent = function(name, fn) events[name] = fn end
AddEventHandler = function(name, fn) events[name] = fn end
LoadResourceFile = function() return 'hello' end
SetResourceKvp = function() end
GetResourceKvpString = function() return nil end
promise = { new = function() return { resolve = function(self, value) self.value = value end } end }
Citizen = { Await = function(p) assert(p.value, 'unexpected unresolved promise'); return p.value end }
PerformHttpRequest = function(url, cb, method, body, headers, options)
    calls[#calls + 1] = { url = url, method = method, body = body, headers = headers, options = options }
    if responseHandler then local status, response = responseHandler(url, method, body); cb(status, json.encode(response), {}); return end
    cb(nextStatus, json.encode(nextBody), {})
end
dofile('config.lua')
dofile('server/core.lua')
dofile('server/files.lua')
dofile('server/logs.lua')
dofile('server/capture.lua')
local checks = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ': ' .. tostring(err)) end
    checks = checks + 1
    print('ok ' .. name)
end
test('reads use bearer auth without redirects', function()
    assert(exposed.ListFilesAwait({ folder = 'phone photos' }).success)
    assert(calls[#calls].url:find('folder=phone%%20photos'))
    assert(calls[#calls].headers.Authorization == 'Bearer bckt_test_key')
    assert(calls[#calls].options.followLocation == false)
end)
test('resource allowlist is enforced', function()
    BcktConfig.allowedResources = { 'other' }
    assert(exposed.ListFilesAwait().error.code == 'RESOURCE_FORBIDDEN')
    BcktConfig.allowedResources = {}
end)
test('invalid ids and recursive deletes never reach the network', function()
    local count = #calls
    assert(not exposed.DeleteFileAwait('../oops').success)
    assert(not exposed.DeleteFolderAwait('phone', {}).success)
    assert(not exposed.DeleteFolderAwait('/', { recursive = true }).success)
    assert(#calls == count)
end)
test('foreign resource reads are denied', function()
    assert(not exposed.UploadResourceFileAwait({ resource = 'secrets', path = 'config.lua' }).success)
    assert(not exposed.UploadResourceFileAwait({ path = '../config.lua' }).success)
end)
test('S3 delete obeys delete permissions', function()
    BcktConfig.deleteResources = { 'admin' }
    assert(exposed.CreateS3UrlAwait({ key = 'photo.jpg', method = 'DELETE' }).error.code == 'RESOURCE_FORBIDDEN')
    BcktConfig.deleteResources = {}
end)
test('mutating 500 responses are uncertain and not retried', function()
    nextStatus, nextBody = 500, { success = false, error = { code = 'INTERNAL_ERROR', message = 'failed' } }
    local count = #calls
    local result = exposed.CreateLogStreamAwait('Server', 'server')
    assert(result.error.uncertain and #calls == count + 1)
end)
test('GET failures retry within the configured bound', function()
    local count = #calls
    assert(not exposed.ListFoldersAwait().success)
    assert(#calls == count + 3)
    nextStatus, nextBody = 200, { success = true }
end)
test('log validation is atomic', function()
    assert(not exposed.LogBatch('server', { { message = 'valid' }, { message = string.rep('x', 16001) } }).success)
    assert(exposed.GetQueueStats().total == 0)
    local payload = {}; payload.self = payload
    assert(not exposed.Log('server', { payload = payload }).success)
end)
test('uncertain logs are retained and require explicit retry', function()
    local queued = exposed.Info('hello', { amount = 42 }); assert(queued.success, queued.error and queued.error.message)
    nextStatus = 500
    assert(not exposed.FlushLogsAwait().success)
    assert(exposed.GetQueueStats().uncertain == 1)
    assert(exposed.RetryLogs().data.queued == 0)
    assert(exposed.RetryLogs({ acceptDuplicateRisk = true }).data.queued == 1)
    nextStatus, nextBody = 202, { success = true, accepted = 1 }
    assert(exposed.FlushLogsAwait().success)
    assert(exposed.GetQueueStats().total == 0)
end)
test('queue overflow reports rejection without dropping existing events', function()
    BcktConfig.maxLogQueue = 1
    assert(exposed.Log('server', { message = 'first' }).success)
    assert(exposed.Log('server', { message = 'second' }).error.code == 'QUEUE_FULL')
    assert(exposed.GetQueueStats().total == 1)
    BcktConfig.maxLogQueue = 5000
end)
test('cross-resource callbacks receive a result exactly once', function()
    local received = 0
    local cb = setmetatable({ __cfx_functionReference = 'test-ref' }, { __call = function(_, result) assert(result.success); received = received + 1 end })
    exposed.ListFolders(cb)
    threads[#threads]()
    for _, fn in ipairs(timers) do fn() end
    assert(received == 1)
end)
test('unrequested client capture events cannot authorize uploads', function()
    local count = #calls
    source = 1
    events['bckt:capture:size']('unknown', 100)
    events['bckt:capture:finished']('unknown', { file_key = 'fake' })
    assert(#calls == count)
end)
test('upload body does not receive the API key', function()
    nextStatus, nextBody = 201, { success = true, file_key = 'abc' }
    local result = Bckt.request('POST', '', 'binary', { upload_url = 'https://upload.bckt.io/v1/upload?token=test', headers = { ['Content-Type'] = 'image/png' } })
    assert(result.success and not calls[#calls].headers.Authorization)
    assert(calls[#calls].body == 'binary')
end)
test('folder paths are normalized consistently', function()
    assert(Bckt.uploadOptions({ filename = 'photo.png', size = 3, folder = ' photos / reports//' }).folder == 'photos/reports')
    assert(not exposed.DeleteFolderAwait(' // ', { recursive = true }).success)
end)
test('a capture binds the player and verifies the uploaded file', function()
    local await = Citizen.Await
    Citizen.Await = function(p)
        if not p.value then coroutine.yield(p) end
        return p.value
    end
    local final, options
    responseHandler = function(url, method, body)
        if url:find('/upload%-url') then
            options = json.decode(body)
            return 201, { success = true, upload_url = 'https://upload.bckt.io/v1/upload?token=test', method = 'POST' }
        elseif url:find('/access%-url') then return 200, { success = true, url = 'https://cdn.bckt.io/verified?token=private', expires_at = '2026-09-18T13:00:00Z' }
        else
            return 200, { success = true, files = { { id = '12345678-1234-1234-1234-123456789abc', original_name = options.filename, public_key = 'verified', size_bytes = '3', mime_type = 'image/webp', is_private = true } } }
        end
    end
    local co = coroutine.create(function() final = exposed.CaptureScreenshotAwait(1, { folder = ' photos/ ' }) end)
    local resumed, err = coroutine.resume(co); assert(resumed, err)
    local started = clientEvents[#clientEvents]
    assert(started.name == 'bckt:capture:start')
    local count = #calls
    source = 2
    events['bckt:capture:size'](started.id, 3)
    assert(#calls == count)
    source = 1
    events['bckt:capture:size'](started.id, 3)
    threads[#threads]()
    assert(options.folder == 'photos' and options.private == true)
    events['bckt:capture:finished'](started.id, { file_key = 'verified' })
    threads[#threads]()
    resumed, err = coroutine.resume(co); assert(resumed, err)
    assert(final.success and final.data.file.public_key == 'verified')
    assert(final.data.url == 'https://cdn.bckt.io/verified?token=private')
    Citizen.Await, responseHandler = await, nil
end)
test('capture provider selection and unavailable resources', function()
    local state, await = GetResourceState, Citizen.Await
    local states = {}
    GetResourceState = function(name) return states[name] or 'missing' end
    assert(exposed.CaptureScreenshotAwait(1, {}).error.code == 'SCREENSHOT_UNAVAILABLE')
    assert(exposed.CaptureScreenshotAwait(1, { provider = 'unknown' }).error.code == 'INVALID_ARGUMENT')
    Citizen.Await = function(p) if not p.value then coroutine.yield(p) end; return p.value end
    local function capture(options, expected)
        local co = coroutine.create(function() exposed.CaptureScreenshotAwait(1, options) end)
        local ok, err = coroutine.resume(co); assert(ok, err)
        local started = clientEvents[#clientEvents]
        assert(started.name == 'bckt:capture:start' and started.value.provider == expected)
        source = 1
        events['bckt:capture:failed'](started.id)
        ok, err = coroutine.resume(co); assert(ok, err)
    end
    states.screencapture = 'started'
    capture({}, 'screencapture')
    assert(exposed.CaptureScreenshotAwait(1, { provider = 'screenshot-basic' }).error.code == 'SCREENSHOT_UNAVAILABLE')
    states['screenshot-basic'] = 'started'
    capture({}, 'screenshot-basic')
    capture({ provider = 'screencapture' }, 'screencapture')
    BcktConfig.captureProvider = 'screencapture'
    capture({}, 'screencapture')
    BcktConfig.captureProvider = 'auto'
    GetResourceState, Citizen.Await = state, await
end)

test('discarding blocked events requires explicit confirmation', function()
    assert(not exposed.DiscardLogs({ state = 'blocked' }).success)
    assert(not exposed.DiscardLogs({ state = 'pending', confirm = true }).success)
end)
test('saved in-flight log events become uncertain after restart', function()
    local saved = json.encode({ { stream = 'server', event = { message = 'saved' }, state = 'sending', attempts = 1, due = 0 } })
    BcktConfig.persistLogs = true
    GetResourceKvpString = function() return saved end
    dofile('server/logs.lua')
    assert(exposed.GetQueueStats().uncertain == 1)
    assert(exposed.GetQueueStats().pending == 0)
    assert(exposed.RetryLogs().data.queued == 0)
    assert(exposed.DiscardLogs({ state = 'uncertain', confirm = true }).data.discarded == 1)
end)
print(checks .. ' SDK checks passed')

