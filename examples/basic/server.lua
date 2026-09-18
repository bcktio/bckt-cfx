RegisterCommand('bckt-example-list', function(player)
    if player ~= 0 then return end
    local result = exports['bckt']:ListFilesAwait({ limit = 10 })
    if not result.success then print(result.error.code, result.error.message); return end
    for _, file in ipairs(result.data.files) do print(file.id, file.original_name) end
end, true)

RegisterCommand('bckt-example-log', function(player)
    if player ~= 0 then return end
    local stream = exports['bckt']:CreateLogStreamAwait('Server events', 'server')
    if not stream.success and stream.error.code ~= 'STREAM_EXISTS' then print(stream.error.message); return end
    local result = exports['bckt']:SendLogsAwait('server', { { event_type = 'sdk.example', message = 'The SDK example is connected.', payload = { example = true } } })
    print(result.success and 'Event accepted by BCKT.' or result.error.message)
end, true)

RegisterCommand('bckt-example-capture', function(player, args)
    if player ~= 0 then return end
    local result = exports['bckt']:CaptureScreenshotAwait(tonumber(args[1]), { private = true })
    if result.success then print('Screenshot stored: ' .. result.data.file.id) else print(result.error.code, result.error.message) end
end, true)
