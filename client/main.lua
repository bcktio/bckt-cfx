local captures, uploads, serial = {}, {}, 0
local function callable(value)
    return type(value) == 'function' or (type(value) == 'table' and rawget(value, '__cfx_functionReference') ~= nil)
end

RegisterNetEvent('bckt:capture:start', function(id, options)
    if source ~= 65535 then return end
    captures[id] = true
    local provider = options.provider or 'screenshot-basic'
    if (provider ~= 'screenshot-basic' and provider ~= 'screencapture') or GetResourceState(provider) ~= 'started' then
        TriggerServerEvent('bckt:capture:failed', id)
        return
    end
    local ok = pcall(function()
        exports[provider]:requestScreenshot({ encoding = options.encoding, quality = options.quality }, function(data)
            if not captures[id] then return end
            if type(data) ~= 'string' or #data > options.maxBytes * 1.4 + 200 then
                TriggerServerEvent('bckt:capture:failed', id)
                return
            end
            SendNUIMessage({ action = 'capture', id = id, data = data, maxBytes = options.maxBytes })
        end)
    end)
    if not ok then TriggerServerEvent('bckt:capture:failed', id) end
end)
RegisterNetEvent('bckt:capture:ticket', function(id, ticket)
    if source ~= 65535 or not captures[id] then return end
    SendNUIMessage({ action = 'ticket', id = id, ticket = ticket })
end)
RegisterNetEvent('bckt:capture:cancel', function(id)
    if source ~= 65535 then return end
    captures[id] = nil
    SendNUIMessage({ action = 'cancel', id = id })
end)
RegisterNUICallback('captureSize', function(data, cb)
    cb({})
    if captures[data.id] then TriggerServerEvent('bckt:capture:size', data.id, data.size) end
end)
RegisterNUICallback('captureFinished', function(data, cb)
    cb({})
    if captures[data.id] then TriggerServerEvent('bckt:capture:finished', data.id, data.receipt) end
end)
RegisterNUICallback('captureFailed', function(data, cb)
    cb({})
    if captures[data.id] then TriggerServerEvent('bckt:capture:failed', data.id) end
end)
local function upload(ticket, data, callback)
    if not callable(callback) then return { success = false, error = { code = 'CALLBACK_REQUIRED', message = 'Provide a callback.' } } end
    if type(ticket) ~= 'table' or type(data) ~= 'string' or #data > 12 * 1024 * 1024 then
        callback({ success = false, error = { code = 'INVALID_ARGUMENT', message = 'Provide a ticket and image data URI of at most 12 MiB.' } })
        return
    end
    local count = 0
    for _ in pairs(uploads) do count = count + 1 end
    if count >= 4 then callback({ success = false, error = { code = 'QUEUE_FULL', message = 'Too many uploads are pending.' } }); return end
    serial = serial + 1
    local id = 'direct-' .. serial
    uploads[id] = callback
    local acknowledged = false
    local event = AddEventHandler('bckt:uploadBridgeStarted', function(startedId)
        if startedId == id then acknowledged = true end
    end)
    SendNUIMessage({ action = 'direct', id = id, ticket = ticket, data = data })
    SetTimeout(5000, function()
        RemoveEventHandler(event)
        if acknowledged or not uploads[id] then return end
        local pending = uploads[id]
        uploads[id] = nil
        SendNUIMessage({ action = 'cancel', id = id })
        print('[bckt] NUI_UNAVAILABLE: The upload bridge did not acknowledge the image. Check the bckt NUI errors in F8.')
        pending({ success = false, error = { code = 'NUI_UNAVAILABLE', message = 'The BCKT upload bridge did not respond. Restart bckt and check F8.', uncertain = true } })
    end)
    SetTimeout(120000, function()
        local pending = uploads[id]
        if pending then
            uploads[id] = nil
            SendNUIMessage({ action = 'cancel', id = id })
            pending({ success = false, error = { code = 'TIMEOUT', message = 'The upload timed out.', uncertain = true } })
        end
    end)
    return { success = true, data = { scheduled = true } }
end
exports('UploadImage', upload)
exports('UploadImageAwait', function(ticket, data)
    local p = promise.new()
    upload(ticket, data, function(result) p:resolve(result) end)
    return Citizen.Await(p)
end)
RegisterNUICallback('directFinished', function(data, cb)
    cb({})
    local callback = uploads[data.id]
    if callback then
        uploads[data.id] = nil
        if not data.result.success then print('[bckt] ' .. tostring(data.result.error.code) .. ': ' .. tostring(data.result.error.message)) end
        callback(data.result)
    end
end)
RegisterNUICallback('directStarted', function(data, cb)
    cb({})
    if uploads[data.id] then TriggerEvent('bckt:uploadBridgeStarted', data.id) end
end)
