local B = Bckt
local queue, flushing, dropped = {}, false, 0
local storageKey = 'bckt:logs:v1'

local function persist()
    if B.config.persistLogs then SetResourceKvp(storageKey, json.encode(queue)) end
end

if B.config.persistLogs then
    local raw = GetResourceKvpString(storageKey)
    if raw then
        local ok, restored = pcall(json.decode, raw)
        if ok and type(restored) == 'table' then
            queue = restored
            for _, item in ipairs(queue) do
                if item.state == 'sending' then item.state = 'uncertain' end
            end
        else
            print('[bckt] The saved log queue could not be read. It has not been overwritten.')
            B.config.persistLogs = false
        end
    end
end

local function streamName(stream)
    stream = stream or B.config.defaultStream
    B.check(type(stream) == 'string' and #stream >= 2 and #stream <= 63 and stream:match('^[a-z0-9][a-z0-9_-]+$'), 'Invalid log stream slug')
    return stream
end

local function clean(value, seen, depth)
    local kind = type(value)
    if kind == 'vector2' or kind == 'vector3' or kind == 'vector4' then
        return { x = value.x, y = value.y, z = kind ~= 'vector2' and value.z or nil, w = kind == 'vector4' and value.w or nil }
    end
    if kind == 'table' then
        B.check(depth < 16 and not seen[value], 'Log payload is circular or too deeply nested')
        seen[value] = true
        local out = {}
        for k, v in pairs(value) do
            B.check(type(k) == 'string' or type(k) == 'number', 'Invalid payload key')
            out[k] = clean(v, seen, depth + 1)
        end
        seen[value] = nil
        return out
    end
    B.check(kind == 'nil' or kind == 'string' or kind == 'boolean' or (kind == 'number' and value == value and math.abs(value) ~= math.huge), 'Unsupported payload value')
    return value
end

local function eventValue(resource, event)
    B.check(type(event) == 'table', 'Expected a log event')
    B.check(event.payload == nil or type(event.payload) == 'table', 'Expected a payload table')
    local payload = clean(event.payload or {}, {}, 0)
    payload._bckt = { resource = resource, tags = clean(B.config.tags, {}, 0) }
    local value = {
        timestamp = event.timestamp or os.date('!%Y-%m-%dT%H:%M:%SZ'),
        level = B.text(event.level or 'info', 'level', 24),
        event_type = event.event_type and B.text(event.event_type, 'event type', 120),
        entity_id = event.entity_id and B.text(event.entity_id, 'entity id', 255),
        message = event.message,
        payload = payload
    }
    B.check(type(value.timestamp) == 'string' and value.timestamp:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d'), 'Use an ISO 8601 timestamp')
    B.check(value.message == nil or (type(value.message) == 'string' and #value.message <= 16000), 'Message exceeds 16000 bytes')
    B.check(#json.encode(value) <= B.config.maxLogEventBytes, 'Log event exceeds the configured size limit')
    return value
end

local function stats()
    local result = { total = #queue, pending = 0, sending = 0, blocked = 0, uncertain = 0, bytes = 0, rejected = dropped }
    for _, item in ipairs(queue) do
        result[item.state] = (result[item.state] or 0) + 1
        result.bytes = result.bytes + #json.encode(item.event)
    end
    return result
end
exports('GetQueueStats', stats)

local function enqueue(resource, stream, events)
    if not B.allowed(resource, 'write') then return B.fail('RESOURCE_FORBIDDEN', 'This resource cannot write logs.') end
    stream = streamName(stream)
    B.check(type(events) == 'table' and #events > 0 and #events <= 1000, 'Provide between 1 and 1000 events')
    local values, bytes = {}, 0
    for _, event in ipairs(events) do
        local value = eventValue(resource, event)
        values[#values + 1] = value
        bytes = bytes + #json.encode(value)
    end
    if #queue + #values > B.config.maxLogQueue or stats().bytes + bytes > B.config.maxLogQueueBytes then
        dropped = dropped + #values
        TriggerEvent('bckt:queueFull', stats())
        return B.fail('QUEUE_FULL', 'The log queue is full. These events were not queued.')
    end
    for _, event in ipairs(values) do queue[#queue + 1] = { stream = stream, event = event, state = 'pending', attempts = 0, due = 0 } end
    persist()
    return B.ok({ queued = #values })
end

local function immediate(name, fn)
    exports(name, function(...)
        local ok, result = pcall(fn, GetInvokingResource(), ...)
        return ok and result or B.fail('INVALID_ARGUMENT', tostring(result))
    end)
end
immediate('Log', function(resource, stream, event) return enqueue(resource, stream, { event }) end)
immediate('LogBatch', enqueue)
for name, level in pairs({ Debug = 'debug', Info = 'info', Warn = 'warn', Error = 'error' }) do
    immediate(name, function(resource, message, payload, stream)
        return enqueue(resource, stream, { { level = level, message = message, payload = payload } })
    end)
end

local function flush()
    if flushing then return B.fail('FLUSH_IN_PROGRESS', 'The log queue is already being flushed.') end
    flushing = true
    local selected, events, stream, bytes = {}, {}, nil, 0
    for _, item in ipairs(queue) do
        local size = #json.encode(item.event)
        if item.state == 'pending' and item.due <= os.time() and (not stream or stream == item.stream) and #events < math.min(1000, B.config.logBatchSize) and bytes + size <= 256000 then
            stream = item.stream
            selected[#selected + 1], events[#events + 1] = item, item.event
            item.state, item.attempts = 'sending', item.attempts + 1
            bytes = bytes + size
        end
    end
    if #events == 0 then flushing = false; return B.ok({ accepted = 0, remaining = #queue }) end
    persist()
    local result = B.request('POST', '/logs/ingest/' .. stream, events)
    local remove = {}
    for _, item in ipairs(selected) do
        if result.success then remove[item] = true
        elseif result.error.uncertain then item.state = 'uncertain'
        elseif (result.status == 429 or result.error.code == 'QUEUE_FULL' or result.error.code == 'QUEUE_TIMEOUT') and item.attempts < 5 then
            item.state = 'pending'
            item.due = os.time() + math.max(math.min(300, 2 ^ item.attempts), result.retry_after or 0)
        else item.state = 'blocked' end
        item.error = not result.success and result.error.code or nil
    end
    local retained = {}
    for _, item in ipairs(queue) do if not remove[item] then retained[#retained + 1] = item end end
    queue = retained
    persist()
    flushing = false
    return result
end
B.register('FlushLogs', 'write', function()
    local accepted = 0
    local rounds = math.ceil(B.config.maxLogQueue / math.max(1, B.config.logBatchSize)) + 1
    for _ = 1, rounds do
        local result = flush()
        if not result.success then return result end
        accepted = accepted + (result.data.accepted or 0)
        if (result.data.accepted or 0) == 0 then break end
    end
    return B.ok({ accepted = accepted, queue = stats() })
end)
immediate('RetryLogs', function(resource, options)
    if not B.allowed(resource, 'write') then return B.fail('RESOURCE_FORBIDDEN', 'This resource cannot retry logs.') end
    options = options or {}
    local count = 0
    for _, item in ipairs(queue) do
        if item.state == 'blocked' or (item.state == 'uncertain' and options.acceptDuplicateRisk == true) then
            item.state, item.due, item.attempts = 'pending', 0, 0
            count = count + 1
        end
    end
    persist()
    return B.ok({ queued = count })
end)
immediate('DiscardLogs', function(resource, options)
    if not B.allowed(resource, 'delete') then return B.fail('RESOURCE_FORBIDDEN', 'This resource cannot discard logs.') end
    B.check(type(options) == 'table' and options.confirm == true, 'Set confirm = true to discard queued events')
    B.check(options.state == 'blocked' or options.state == 'uncertain', 'Choose blocked or uncertain events')
    local retained, count = {}, 0
    for _, item in ipairs(queue) do
        if item.state == options.state then count = count + 1 else retained[#retained + 1] = item end
    end
    queue = retained
    persist()
    return B.ok({ discarded = count })
end)
B.register('SendLogs', 'write', function(resource, stream, events)
    stream = streamName(stream)
    B.check(type(events) == 'table', 'Expected events')
    if events.message or events.payload or events.event_type then events = { events } end
    B.check(#events > 0 and #events <= 1000, 'Provide between 1 and 1000 events')
    local values = {}
    for _, event in ipairs(events) do values[#values + 1] = eventValue(resource, event) end
    B.check(#json.encode(values) <= 256000, 'Use LogBatch for batches larger than 256 KB')
    return B.request('POST', '/logs/ingest/' .. stream, values)
end)
B.register('ListLogStreams', nil, function() return B.request('GET', '/logs/streams') end)
B.register('CreateLogStream', 'write', function(_, name, slug)
    B.text(name, 'stream name', 80)
    B.check(#name >= 2, 'Stream name is too short')
    return B.request('POST', '/logs/streams', { name = name, slug = streamName(slug) })
end)
B.register('QueryLogs', nil, function(_, filters)
    B.check(type(filters) == 'table' and filters.from and filters.to and filters.stream, 'Provide stream, from and to')
    return B.request('GET', '/logs/query' .. B.query(filters))
end)
CreateThread(function()
    while true do
        Wait(B.config.logIntervalMs)
        if not flushing then flush() end
    end
end)
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then persist() end
end)
