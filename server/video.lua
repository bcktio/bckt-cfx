local B = Bckt

local function integer(value, fallback, minimum, maximum, name)
    value = value == nil and fallback or value
    B.check(type(value) == 'number' and value % 1 == 0 and value >= minimum and value <= maximum, 'Invalid ' .. name)
    return value
end

local function operation(resource, name, argument, options)
    local pending = promise.new()
    local function bridge(action, metadata, callback)
        CreateThread(function()
            local success, result = pcall(function()
                if action == 'authorize' then return B.methods.CreateUploadUrl(resource, metadata) end
                if action ~= 'verify' then return B.fail('INVALID_ARGUMENT', 'Unknown video API operation.') end
                local list = B.methods.ListFiles(resource, { folder = metadata.folder, search = metadata.filename, limit = 10 })
                if not list.success then return list end
                for _, file in ipairs(list.data.files or {}) do
                    if file.original_name == metadata.filename and file.public_key == metadata.file_key and tonumber(file.size_bytes) == metadata.size and file.mime_type == 'video/webm' and file.is_private == metadata.private then
                        local access = B.methods.GetFileUrl(resource, file.id)
                        if not access.success then return access end
                        return B.ok({ file = file, url = access.data.url, expires_at = access.data.expires_at })
                    end
                end
                return B.fail('UPLOAD_UNVERIFIED', 'The video could not be verified against the file catalog.', 0, true)
            end)
            callback(success and result or B.fail('VIDEO_API_FAILED', 'The video API request failed.', 0, action == 'verify'))
        end)
    end
    local sent = pcall(function()
        exports[GetCurrentResourceName()]:_video(name, resource, argument, options or {}, bridge, function(result) pending:resolve(result) end)
    end)
    if not sent then return B.fail('VIDEO_TRANSPORT_UNAVAILABLE', 'Restart bckt with the complete resource, including server/video.js.') end
    return Citizen.Await(pending)
end

B.register('StartVideoCapture', 'write', function(resource, player, options)
    player = tonumber(player)
    B.check(player and player % 1 == 0 and player > 0 and GetPlayerName(player), 'Player is not connected')
    if GetResourceState('screencapture') ~= 'started' then return B.fail('CAPTURE_UNAVAILABLE', 'Start screencapture to record videos.') end
    options = options or {}
    B.check(type(options) == 'table', 'Expected video options')
    local maxDuration = integer(B.config.maxVideoDurationSeconds, 120, 1, 600, 'maximum video duration')
    local maxBytes = integer(B.config.maxVideoBytes, 64 * 1024 * 1024, 1, 98 * 1024 * 1024, 'maximum video size')
    local values = {
        duration = integer(options.duration, math.min(30, maxDuration), 1, maxDuration, 'video duration'),
        maxWidth = integer(options.maxWidth, 1280, 1, 3840, 'video width'),
        maxHeight = integer(options.maxHeight, 720, 1, 2160, 'video height'),
        maxBytes = integer(options.maxBytes, maxBytes, 1, maxBytes, 'video size limit'),
        maxCaptures = integer(B.config.maxVideoCaptures, 2, 1, 16, 'video concurrency'),
        finishTimeoutMs = integer(B.config.videoFinishTimeoutMs, 120000, 1000, 300000, 'video finish timeout'),
        uploadTimeoutMs = integer(B.config.videoUploadTimeoutMs, 120000, 1000, 300000, 'video upload timeout'),
    }
    B.check(options.private == nil or type(options.private) == 'boolean', 'Invalid video privacy setting')
    local metadata = B.uploadOptions({ filename = options.filename or 'recording.webm', folder = options.folder or 'recordings', private = options.private ~= false, size = 1, content_type = 'video/webm' })
    B.check(metadata.filename:lower():sub(-5) == '.webm', 'Video filename must end in .webm')
    values.filename, values.folder, values.private = options.filename, metadata.folder, metadata.private
    return operation(resource, 'start', player, values)
end)

for name, action in pairs({ GetVideoCaptureStatus = 'status', IsVideoCaptureActive = 'status', StopVideoCapture = 'stop', CancelVideoCapture = 'cancel', WaitVideoCapture = 'wait' }) do
    B.register(name, 'write', function(resource, id)
        B.text(id, 'capture id', 64)
        return operation(resource, action, id)
    end)
end

B.register('CaptureVideo', 'write', function(resource, player, options)
    local result = B.methods.StartVideoCapture(resource, player, options)
    if not result.success then return result end
    return operation(resource, 'wait', result.data.capture_id)
end)
