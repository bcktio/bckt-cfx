local exposed, callbacks, handlers, timers, messages = {}, {}, {}, {}, {}
exports = function(name, fn) exposed[name] = fn end
RegisterNetEvent = function() end
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
