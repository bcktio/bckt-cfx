Bckt = { config = BcktConfig, methods = {}, active = 0, pending = 0, version = '0.1.3' }
local B = Bckt
local key = GetConvar('bckt_api_key', '')
local base = 'https://api.bckt.io/api/v1'
local status = { connection = 'unknown' }

function B.fail(code, message, http, uncertain)
    return { success = false, status = http or 0, error = { code = code, message = message, uncertain = uncertain or false } }
end

function B.ok(data, http)
    return { success = true, status = http or 200, data = data or {} }
end

function B.check(condition, message)
    if not condition then error(message, 0) end
end

function B.text(value, name, max)
    B.check(type(value) == 'string' and #value > 0 and #value <= max and not value:find('%c'), 'Invalid ' .. name)
    return value
end

function B.uuid(value)
    B.text(value, 'file id', 36)
    B.check(value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'), 'Invalid file id')
    return value
end

function B.encode(value)
    return (tostring(value):gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end))
end

function B.query(values)
    local parts = {}
    for k, v in pairs(values or {}) do
        B.check(type(v) == 'string' or type(v) == 'number' or type(v) == 'boolean', 'Invalid query value')
        parts[#parts + 1] = B.encode(k) .. '=' .. B.encode(v)
    end
    table.sort(parts)
    return #parts > 0 and ('?' .. table.concat(parts, '&')) or ''
end

function B.allowed(resource, kind)
    local function has(list)
        if #list == 0 then return true end
        for _, name in ipairs(list) do if name == resource then return true end end
        return false
    end
    return resource and has(B.config.allowedResources) and (not kind or has(B.config[kind .. 'Resources']))
end

local byteHex = {}
for i = 0, 255 do byteHex[string.char(i)] = string.format('%02x', i) end

local function once(method, url, body, headers, binary)
    local p = promise.new()
    local finished = false
    local function finish(value)
        if finished then return end
        finished = true
        p:resolve(value)
    end
    SetTimeout(B.config.requestTimeoutMs, function()
        finish(B.fail('TIMEOUT', 'The request timed out. Its outcome may be unknown.', 0, method ~= 'GET'))
    end)
    local function response(code, raw, responseHeaders, errorData)
        code = tonumber(code) or 0
        if (raw == nil or raw == '') and type(errorData) == 'string' then
            raw = errorData:match('^HTTP %d+:%s*(.*)$') or errorData
        end
        local parsed, value = pcall(json.decode, raw or '')
        if code >= 200 and code < 300 then
            if code == 204 then finish(B.ok({}, code))
            elseif parsed and type(value) == 'table' and value.success ~= false then
                local result = B.ok(value, code)
                result.request_id = value.request_id
                finish(result)
            else finish(B.fail('INVALID_RESPONSE', 'BCKT returned an unexpected response.', code, method ~= 'GET')) end
        else
            local err = parsed and type(value) == 'table' and value.error
            local result = B.fail(type(err) == 'table' and err.code or 'HTTP_ERROR', type(err) == 'table' and err.message or 'The request failed.', code, method ~= 'GET' and (code == 0 or code >= 500))
            result.request_id = parsed and type(value) == 'table' and value.request_id or nil
            for name, header in pairs(responseHeaders or {}) do
                if name:lower() == 'retry-after' then result.retry_after = tonumber(header) end
            end
            finish(result)
        end
    end
    local sent = pcall(function()
        if binary then
            local hex = body:gsub('.', byteHex)
            exports[GetCurrentResourceName()]:_uploadBytes(method, url, hex, headers, B.config.requestTimeoutMs, response)
        else
            PerformHttpRequest(url, response, method, body or '', headers, { followLocation = false })
        end
    end)
    if not sent then finish(B.fail('TRANSPORT_ERROR', 'The HTTP request could not be started.')) end
    return Citizen.Await(p)
end

function B.request(method, path, value, upload)
    if key == '' then return B.fail('NOT_CONFIGURED', 'Set bckt_api_key on the server.') end
    if B.pending >= B.config.maxPendingRequests then return B.fail('QUEUE_FULL', 'The request queue is full.') end
    local body = upload and value or (value and json.encode(value) or '')
    B.pending = B.pending + 1
    local deadline = GetGameTimer() + B.config.requestTimeoutMs
    while B.active >= B.config.requestConcurrency do
        if GetGameTimer() >= deadline then
            B.pending = B.pending - 1
            return B.fail('QUEUE_TIMEOUT', 'The request expired before it was sent.')
        end
        Wait(25)
    end
    B.pending = B.pending - 1
    B.active = B.active + 1
    local url, headers = base .. path, { Authorization = 'Bearer ' .. key, ['Content-Type'] = 'application/json' }
    if upload then
        url, headers = upload.upload_url, upload.headers
        if type(url) ~= 'string' or not url:match('^https://upload%.bckt%.io/') then
            B.active = B.active - 1
            return B.fail('INVALID_UPLOAD_HOST', 'Unexpected upload destination.')
        end
    end
    local result
    for attempt = 0, method == 'GET' and B.config.readRetries or 0 do
        result = once(method, url, body, headers, upload ~= nil)
        if result.success or not (result.status == 0 or result.status == 429 or result.status >= 500) or attempt == B.config.readRetries then break end
        if (result.retry_after or 0) > 60 then break end
        Wait(math.min(60000, math.max(1000 * 2 ^ attempt, (result.retry_after or 0) * 1000)))
    end
    B.active = B.active - 1
    status.lastRequestAt = os.date('!%Y-%m-%dT%H:%M:%SZ')
    status.connection = result.status > 0 and 'reachable' or 'unreachable'
    status.lastError = not result.success and result.error.code or nil
    if not result.success then TriggerEvent('bckt:requestFailed', { code = result.error.code, status = result.status, request_id = result.request_id }) end
    return result
end

function B.register(name, kind, fn)
    B.methods[name] = fn
    local function invoke(resource, args)
        if not B.allowed(resource, kind) then return B.fail('RESOURCE_FORBIDDEN', 'This resource is not authorized.') end
        local ok, result = pcall(fn, resource, table.unpack(args, 1, args.n))
        if not ok then return B.fail('INVALID_ARGUMENT', tostring(result)) end
        return result
    end
    exports(name .. 'Await', function(...)
        return invoke(GetInvokingResource(), table.pack(...))
    end)
    exports(name, function(...)
        local resource, args = GetInvokingResource(), table.pack(...)
        local cb = args[args.n]
        if not (type(cb) == 'function' or (type(cb) == 'table' and rawget(cb, '__cfx_functionReference') ~= nil)) then return B.fail('CALLBACK_REQUIRED', 'Provide a callback or use the Await export.') end
        args[args.n], args.n = nil, args.n - 1
        CreateThread(function()
            local result = invoke(resource, args)
            if GetResourceState(resource) == 'started' then pcall(cb, result) end
        end)
        return B.ok({ scheduled = true })
    end)
end

exports('IsReady', function() return key ~= '' end)
exports('GetVersion', function() return B.version end)
exports('GetStatus', function()
    return { ready = key ~= '', connection = status.connection, last_request_at = status.lastRequestAt, last_error = status.lastError, active_requests = B.active, pending_requests = B.pending }
end)
CreateThread(function()
    Wait(0)
    if key ~= '' then TriggerEvent('bckt:ready') else print('[bckt] Set bckt_api_key before starting this resource.') end
end)
