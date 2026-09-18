local pending, sequence = {}, 0
exports('UploadPhoneImage', function(dataUri, callback)
    if not (type(callback) == 'function' or (type(callback) == 'table' and rawget(callback, '__cfx_functionReference') ~= nil)) then return end
    local function reject(message) callback({ success = false, error = { code = 'INVALID_IMAGE', message = message } }) end
    if type(dataUri) ~= 'string' or #dataUri > 12 * 1024 * 1024 then reject('Image is too large.'); return end
    local mime, body = dataUri:match('^data:(image/[%a]+);base64,([%w+/=]+)$')
    if not mime or #body % 4 ~= 0 then reject('Expected a base64 image data URI.'); return end
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    if count > 0 then reject('Another photo is uploading.'); return end
    local padding = body:sub(-2) == '==' and 2 or (body:sub(-1) == '=' and 1 or 0)
    local size = #body / 4 * 3 - padding
    sequence = sequence + 1
    local id = tostring(sequence)
    pending[id] = { data = dataUri, callback = callback }
    SetTimeout(125000, function()
        local task = pending[id]
        if task then
            pending[id] = nil
            task.callback({ success = false, error = { code = 'TIMEOUT', message = 'The phone upload timed out.', uncertain = true } })
        end
    end)
    TriggerServerEvent('bckt-phone:authorize', id, size, mime)
end)
RegisterNetEvent('bckt-phone:ticket', function(id, ticket)
    if source ~= 65535 then return end
    local task = pending[id]
    if not task or task.uploading then return end
    task.uploading = true
    exports['bckt']:UploadImage(ticket, task.data, function(result)
        if pending[id] ~= task then return end
        task.data = nil
        TriggerServerEvent('bckt-phone:receipt', id, result.success and result.data.file_key or nil)
    end)
end)
RegisterNetEvent('bckt-phone:result', function(id, result)
    if source ~= 65535 then return end
    local task = pending[id]
    if task then pending[id] = nil; task.callback(result) end
end)
