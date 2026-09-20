local exposed, callbacks, handlers, timers, messages = {}, {}, {}, {}, {}
exports = setmetatable({}, { __call = function(_, name, fn) exposed[name] = fn end })
local events = {}
RegisterNetEvent = function(name, fn) events[name] = fn end
RegisterNUICallback = function(name, fn) callbacks[name] = fn end
AddEventHandler = function(name, fn) handlers[name] = fn; return name end
RemoveEventHandler = function(id) handlers[id] = nil end
TriggerEvent = function(name, ...) if handlers[name] then handlers[name](...) end end
SendNUIMessage = function(message) messages[#messages + 1] = message end
SetTimeout = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
dofile('client/main.lua')
local count, last = 0, nil
local callback = setmetatable({ __cfx_functionReference = 'client-ref' }, { __call = function(_, result) count = count + 1; last = result end })
local result = exposed.UploadImage({}, 'data:image/png;base64,YWJj', callback)
assert(result.success and #messages == 1, 'Cfx callback was rejected')
local id = messages[1].id
callbacks.directStarted({ id = id }, function() end)
timers[1].fn()
assert(count == 0, 'acknowledged upload incorrectly timed out')
callbacks.directFinished({ id = id, result = { success = true } }, function() end)
assert(count == 1 and last.success, 'Cfx callback was not delivered')
timers[2].fn()
assert(count == 1, 'callback was delivered twice')
exposed.UploadImage({}, 'data:image/png;base64,YWJj', callback)
timers[3].fn()
assert(count == 2 and last.error.code == 'NUI_UNAVAILABLE', 'missing bridge did not report a failure')
print('2 client callback and bridge checks passed')

local failures, captured = 0, nil
TriggerServerEvent = function(name) if name == 'bckt:capture:failed' then failures = failures + 1 end end
GetResourceState = function() return 'started' end
source = 65535
for _, provider in ipairs({ 'screenshot-basic', 'screencapture' }) do
    exports[provider] = { requestScreenshot = function(_, options, cb)
        captured = options
        cb('data:image/webp;base64,YWJj')
    end }
    events['bckt:capture:start'](provider, { provider = provider, encoding = 'webp', quality = 0.85, maxBytes = 1024 })
    assert(captured.encoding == 'webp' and captured.quality == 0.85)
    assert(messages[#messages].action == 'capture' and messages[#messages].id == provider)
end
exports.screencapture.requestScreenshot = function() error('capture failed') end
events['bckt:capture:start']('failure', { provider = 'screencapture' })
assert(failures == 1)
events['bckt:capture:start']('invalid', { provider = 'other' })
assert(failures == 2)
source = 1
events['bckt:capture:start']('forged', { provider = 'screencapture' })
assert(failures == 2)
print('capture adapters and failure checks passed')
