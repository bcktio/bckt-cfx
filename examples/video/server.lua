local active = {}

local function report(player, message)
    if player == 0 then print('[bckt-video] ' .. message)
    else TriggerClientEvent('chat:addMessage', player, { args = { 'BCKT', message } }) end
end

RegisterCommand('bckt-video', function(source, args)
    local operator = source
    local target, duration = tonumber(args[1]), tonumber(args[2]) or 15
    if not target or not GetPlayerName(target) then report(operator, 'Use bckt-video <player id> [seconds]'); return end
    if active[operator] then report(operator, 'Stop or cancel your pending recording first.'); return end
    active[operator] = true
    CreateThread(function()
        local started = exports['bckt']:StartVideoCaptureAwait(target, { duration = duration, folder = 'reports/clips', private = true })
        if not started.success then active[operator] = nil; report(operator, started.error.message); return end
        local id = started.data.capture_id
        active[operator] = id
        report(operator, 'Recording started. Use bckt-video-stop or bckt-video-cancel.')
        local result = exports['bckt']:WaitVideoCaptureAwait(id)
        if active[operator] == id then active[operator] = nil end
        report(operator, result.success and ('Saved file: ' .. result.data.file.id) or (result.error.code .. ': ' .. result.error.message))
    end)
end, true)

for command, export in pairs({ ['bckt-video-stop'] = 'StopVideoCaptureAwait', ['bckt-video-cancel'] = 'CancelVideoCaptureAwait', ['bckt-video-status'] = 'GetVideoCaptureStatusAwait' }) do
    RegisterCommand(command, function(source)
        local operator, id = source, active[source]
        if type(id) ~= 'string' then report(operator, 'No recording is ready to control.'); return end
        CreateThread(function()
            local result = exports['bckt'][export](exports['bckt'], id)
            report(operator, result.success and result.data.state or result.error.message)
        end)
    end, true)
end
