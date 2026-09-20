local B = Bckt

local function folderPath(value)
    B.check(type(value) == 'string' and #value <= 512 and not value:find('%c'), 'Invalid folder')
    local parts = {}
    for part in value:gmatch('[^/\\]+') do
        part = part:match('^%s*(.-)%s*$')
        B.check(part ~= '..' and part ~= '.', 'Invalid folder segment')
        if part ~= '' then parts[#parts + 1] = part end
    end
    return table.concat(parts, '/')
end

function B.uploadOptions(o)
    B.check(type(o) == 'table', 'Expected upload options')
    B.text(o.filename, 'filename', 512)
    B.check(not o.filename:find('[/\\]') and o.filename ~= '.' and o.filename ~= '..', 'Filename must not contain a path')
    B.check(type(o.size) == 'number' and o.size > 0 and o.size % 1 == 0 and o.size <= 98 * 1024 * 1024, 'Size must be between 1 byte and 98 MiB for a single upload')
    local folder = folderPath(o.folder or B.config.defaultFolder)
    B.check(o.private == nil or type(o.private) == 'boolean', 'Invalid privacy setting')
    return { filename = o.filename, size = o.size, folder = folder, content_type = B.text(o.content_type or 'application/octet-stream', 'content type', 255), private = o.private == true }
end

B.register('CreateUploadUrl', 'write', function(_, o)
    return B.request('POST', '/files/upload-url', B.uploadOptions(o))
end)

local function upload(_, o)
    B.check(type(o) == 'table' and type(o.data) == 'string', 'Expected data as a binary or text string')
    B.check(#o.data <= B.config.maxUploadBytes, 'File exceeds the server upload limit')
    local opts = B.uploadOptions({ filename = o.filename, folder = o.folder, content_type = o.content_type, private = o.private, size = #o.data })
    local ticket = B.request('POST', '/files/upload-url', opts)
    if not ticket.success then return ticket end
    local method = ticket.data.method or 'POST'
    B.check(method == 'POST' or method == 'PUT', 'The upload ticket returned an unsupported method')
    return B.request(method, '', o.data, ticket.data)
end
B.register('UploadFile', 'write', upload)
B.register('UploadJson', 'write', function(resource, o)
    B.check(type(o) == 'table' and type(o.data) == 'table', 'Expected a Lua table in data')
    return upload(resource, { data = json.encode(o.data), filename = o.filename, folder = o.folder, private = o.private, content_type = 'application/json' })
end)
B.register('UploadResourceFile', 'write', function(resource, o)
    B.check(type(o) == 'table', 'Expected file options')
    local target = o.resource or resource
    B.check(target == resource or B.config.fileResources[target] == true, 'Reading another resource requires fileResources permission')
    B.text(o.path, 'path', 512)
    B.check(not o.path:find('[:\\]') and o.path:sub(1, 1) ~= '/', 'Use a relative resource path')
    for part in o.path:gmatch('[^/]+') do B.check(part ~= '..' and part ~= '.', 'Invalid resource path') end
    local data = LoadResourceFile(target, o.path)
    if not data then return B.fail('FILE_NOT_FOUND', 'The resource file could not be read.') end
    return upload(resource, { data = data, filename = o.filename or o.path:match('[^/]+$'), folder = o.folder, private = o.private, content_type = o.content_type })
end)
B.register('ListFiles', nil, function(_, filters)
    local query = {}
    for k, v in pairs(filters or {}) do query[k] = v end
    if query.folder then query.folder = folderPath(query.folder) end
    return B.request('GET', '/files' .. B.query(query))
end)
B.register('ListFolders', nil, function() return B.request('GET', '/files/folders') end)
B.register('GetFileUrl', nil, function(_, id) return B.request('POST', '/files/' .. B.uuid(id) .. '/access-url') end)
B.register('SetFileVisibility', 'write', function(_, id, private)
    B.check(type(private) == 'boolean', 'Expected a boolean privacy value')
    return B.request('PATCH', '/files/' .. B.uuid(id) .. '/visibility', { is_private = private })
end)
local function delete(_, id) return B.request('DELETE', '/files/' .. B.uuid(id)) end
B.register('DeleteFile', 'delete', delete)
B.register('DeleteFiles', 'delete', function(resource, ids)
    B.check(type(ids) == 'table' and #ids > 0 and #ids <= 100, 'Provide between 1 and 100 file ids')
    for _, id in ipairs(ids) do B.uuid(id) end
    local results, failed = {}, 0
    for _, id in ipairs(ids) do
        local result = delete(resource, id)
        results[#results + 1] = { id = id, result = result }
        if not result.success then failed = failed + 1 end
    end
    return B.ok({ results = results, failed = failed, deleted = #ids - failed })
end)
B.register('DeleteFolder', 'delete', function(_, path, o)
    B.check(type(o) == 'table' and o.recursive == true, 'Set recursive = true to delete a folder and its contents')
    path = folderPath(path)
    B.check(path ~= '', 'Deleting the root is not supported')
    return B.request('DELETE', '/files/folders' .. B.query({ path = path }))
end)
B.register('CreateS3Url', nil, function(resource, o)
    B.check(type(o) == 'table', 'Expected S3 options')
    local method = o.method or 'PUT'
    B.check(method == 'PUT' or method == 'GET' or method == 'HEAD' or method == 'DELETE', 'Invalid S3 method')
    if not B.allowed(resource, method == 'DELETE' and 'delete' or (method == 'PUT' and 'write' or nil)) then return B.fail('RESOURCE_FORBIDDEN', 'This resource cannot perform that S3 operation.') end
    return B.request('POST', '/files/s3-url', { key = B.text(o.key, 'object key', 1024), method = method, expires_in = o.expires_in })
end)
