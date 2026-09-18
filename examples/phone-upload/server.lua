local pending, lastUpload, sequence = {}, {}, 0
local mimeExtensions = { ['image/jpeg'] = 'jpg', ['image/png'] = 'png', ['image/webp'] = 'webp' }
local function fail(code, message)
    return { success = false, error = { code = code, message = message } }
end
local function finish(player, task, result)
    if pending[player] ~= task then return end
    pending[player] = nil
    TriggerClientEvent('bckt-phone:result', player, task.id, result)
end
RegisterNetEvent('bckt-phone:authorize', function(id, size, mime)
    local player = source
    if type(id) ~= 'string' or #id > 64 then return end
    if not IsPlayerAceAllowed(player, 'bckt.example.phone') then
        TriggerClientEvent('bckt-phone:result', player, id, fail('FORBIDDEN', 'Phone uploads are not enabled for this player.'))
        return
    end
    if pending[player] or (lastUpload[player] and os.time() - lastUpload[player] < 15) then
        TriggerClientEvent('bckt-phone:result', player, id, fail('RATE_LIMITED', 'Wait before uploading another photo.'))
        return
    end
    local active = 0
    for _ in pairs(pending) do active = active + 1 end
    if active >= 8 or type(size) ~= 'number' or size % 1 ~= 0 or size < 1 or size > 8 * 1024 * 1024 or not mimeExtensions[mime] then
        TriggerClientEvent('bckt-phone:result', player, id, fail('INVALID_UPLOAD', 'The upload is not allowed or the upload queue is full.'))
        return
    end
    sequence = sequence + 1
    lastUpload[player] = os.time()
    local task = {
        id = id, size = size, mime = mime, state = 'authorizing', folder = 'phone/photos',
        filename = string.format('phone-%x-%x-%x.%s', os.time(), sequence, math.random(0, 0x7fffffff), mimeExtensions[mime])
    }
    pending[player] = task
    SetTimeout(120000, function() finish(player, task, fail('TIMEOUT', 'The photo upload timed out.')) end)
    CreateThread(function()
        local result = exports['bckt']:CreateUploadUrlAwait({ filename = task.filename, size = size, content_type = mime, folder = task.folder, private = false })
        if pending[player] ~= task then return end
        if not result.success then finish(player, task, result); return end
        task.state = 'upload'
        TriggerClientEvent('bckt-phone:ticket', player, id, result.data)
    end)
end)
RegisterNetEvent('bckt-phone:receipt', function(id, fileKey)
    local player = source
    local task = pending[player]
    if not task or task.id ~= id or task.state ~= 'upload' then return end
    if type(fileKey) ~= 'string' or #fileKey > 512 then finish(player, task, fail('UPLOAD_FAILED', 'No valid receipt was received.')); return end
    task.state = 'verifying'
    CreateThread(function()
        local result = exports['bckt']:ListFilesAwait({ folder = task.folder, search = task.filename, limit = 10 })
        if pending[player] ~= task then return end
        if not result.success then finish(player, task, result); return end
        for _, file in ipairs(result.data.files) do
            if file.public_key == fileKey and file.original_name == task.filename and tonumber(file.size_bytes) == task.size and file.mime_type == task.mime and file.is_private == false then
                TriggerEvent('bckt-phone:verified', player, file)
                finish(player, task, { success = true, data = { file = file, url = file.url } })
                return
            end
        end
        finish(player, task, fail('UPLOAD_UNVERIFIED', 'The photo could not be verified.'))
    end)
end)
AddEventHandler('playerDropped', function()
    pending[source], lastUpload[source] = nil, nil
end)
