local B = Bckt
local captures, sequence = {}, 0

local function complete(id, result)
    local task = captures[id]
    if not task then return end
    captures[id] = nil
    TriggerClientEvent('bckt:capture:cancel', task.player, id)
    task.promise:resolve(result)
end

B.register('CaptureScreenshot', 'write', function(resource, player, options)
    player = tonumber(player)
    B.check(player and player > 0 and GetPlayerName(player), 'Player is not connected')
    options = options or {}
    B.check(type(options) == 'table', 'Expected capture options')
    local provider = options.provider or B.config.captureProvider or 'auto'
    B.check(provider == 'auto' or provider == 'screenshot-basic' or provider == 'screencapture', 'Use auto, screenshot-basic or screencapture as the capture provider')
    if provider == 'auto' then
        provider = GetResourceState('screenshot-basic') == 'started' and 'screenshot-basic' or 'screencapture'
    end
    if GetResourceState(provider) ~= 'started' then return B.fail('SCREENSHOT_UNAVAILABLE', 'Start screenshot-basic or screencapture, or check the selected capture provider.') end
    local count = 0
    for _, task in pairs(captures) do
        count = count + 1
        if task.player == player then return B.fail('CAPTURE_IN_PROGRESS', 'This player already has a pending capture.') end
    end
    if count >= B.config.maxCaptures then return B.fail('CAPTURE_QUEUE_FULL', 'Too many screenshots are pending.') end
    local encoding = options.encoding or 'webp'
    B.check(encoding == 'jpg' or encoding == 'png' or encoding == 'webp', 'Use jpg, png or webp')
    local quality = options.quality or 0.85
    B.check(type(quality) == 'number' and quality > 0 and quality <= 1, 'Quality must be greater than 0 and at most 1')
    for name, limit in pairs({ maxWidth = 3840, maxHeight = 2160 }) do
        local value = options[name]
        B.check(value == nil or (type(value) == 'number' and value % 1 == 0 and value >= 1 and value <= limit), 'Invalid screenshot dimensions')
        B.check(value == nil or provider == 'screencapture', 'Screenshot dimensions require screencapture')
    end
    sequence = sequence + 1
    local id = string.format('%x-%x-%x', os.time(), sequence, math.random(0, 0x7fffffff))
    local mime = encoding == 'jpg' and 'image/jpeg' or 'image/' .. encoding
    local validated = B.uploadOptions({ filename = 'capture-' .. id .. '.' .. encoding, size = 1, folder = options.folder or 'screenshots', content_type = mime, private = options.private ~= false })
    local task = { player = player, resource = resource, promise = promise.new(), options = validated, state = 'capture' }
    captures[id] = task
    SetTimeout(B.config.captureTimeoutMs, function()
        complete(id, B.fail('CAPTURE_TIMEOUT', 'The capture timed out. A started upload may still complete.', 0, task.state ~= 'capture'))
    end)
    TriggerClientEvent('bckt:capture:start', player, id, { provider = provider, encoding = encoding, quality = quality, maxWidth = options.maxWidth, maxHeight = options.maxHeight, maxBytes = B.config.maxCaptureBytes })
    return Citizen.Await(task.promise)
end)

RegisterNetEvent('bckt:capture:size', function(id, size)
    local player = source
    if type(id) ~= 'string' then return end
    local task = captures[id]
    if not task or task.player ~= player or task.state ~= 'capture' then return end
    if type(size) ~= 'number' or size % 1 ~= 0 or size < 1 or size > B.config.maxCaptureBytes then
        complete(id, B.fail('INVALID_CAPTURE_SIZE', 'The screenshot exceeds the configured limit.'))
        return
    end
    task.state, task.options.size = 'authorizing', size
    CreateThread(function()
        local result = B.request('POST', '/files/upload-url', task.options)
        if captures[id] ~= task then return end
        if not result.success then complete(id, result); return end
        task.state = 'upload'
        TriggerClientEvent('bckt:capture:ticket', player, id, result.data)
    end)
end)

RegisterNetEvent('bckt:capture:finished', function(id, receipt)
    local player = source
    if type(id) ~= 'string' then return end
    local task = captures[id]
    if not task or task.player ~= player or task.state ~= 'upload' then return end
    if type(receipt) ~= 'table' or type(receipt.file_key) ~= 'string' or #receipt.file_key > 512 then
        complete(id, B.fail('INVALID_RECEIPT', 'The client returned an invalid upload receipt.'))
        return
    end
    task.state = 'verifying'
    CreateThread(function()
        local result = B.request('GET', '/files' .. B.query({ folder = task.options.folder, search = task.options.filename, limit = 10 }))
        if captures[id] ~= task then return end
        if not result.success then complete(id, result); return end
        for _, file in ipairs(result.data.files or {}) do
            if file.original_name == task.options.filename and file.public_key == receipt.file_key and tonumber(file.size_bytes) == task.options.size and file.mime_type == task.options.content_type and file.is_private == task.options.private then
                local link = B.methods.GetFileUrl(task.resource, file.id)
                if not link.success then complete(id, link); return end
                complete(id, B.ok({ file = file, url = link.data.url, expires_at = link.data.expires_at }))
                return
            end
        end
        complete(id, B.fail('UPLOAD_UNVERIFIED', 'The upload could not be verified against the file catalog.'))
    end)
end)

RegisterNetEvent('bckt:capture:failed', function(id)
    local task = type(id) == 'string' and captures[id]
    if task and task.player == source then complete(id, B.fail('CLIENT_CAPTURE_FAILED', 'The client could not finish the capture or upload.', 0, task.state == 'upload')) end
end)
AddEventHandler('playerDropped', function()
    local player = source
    for id, task in pairs(captures) do
        if task.player == player then complete(id, B.fail('PLAYER_DISCONNECTED', 'The player disconnected.', 0, task.state == 'upload')) end
    end
end)
AddEventHandler('onResourceStop', function(resource)
    for id, task in pairs(captures) do
        if task.resource == resource then complete(id, B.fail('RESOURCE_STOPPED', 'The requesting resource stopped.')) end
    end
end)
