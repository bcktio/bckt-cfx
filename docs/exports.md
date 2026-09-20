# Export reference

The resource name is `bckt`. Except for `UploadImage`, all exports below run on the server.

## Calling conventions

HTTP exports accept a callback as their final argument. Their immediate return only confirms scheduling. `NameAwait` returns the completed result and must run in a yieldable thread.

```lua
exports['bckt']:ListFiles({ folder = 'photos' }, function(result)
    if result.success then
        for _, file in ipairs(result.data.files) do print(file.id) end
    end
end)
```

Results have `success`, `status` and `data` on success. Failure results have `error.code`, `error.message`, `error.uncertain` and, when supplied by BCKT, `request_id` and numeric `retry_after` in seconds. Local failures have status `0`. An HTTP 204 is a successful result with an empty data table.

`data` retains the API response fields, including its `success` property. Do not assume all successful operations return a file object.

## Storage

| Export and arguments | Scope | Successful data |
| --- | --- | --- |
| `CreateUploadUrl(options)` | `files:write` | `upload_url`, `method`, `headers`, `max_bytes`, `expires_at` |
| `UploadFile(options)` | `files:write` | `url`, `file_key`, `size`, `is_private`, `moderation_status` |
| `UploadJson(options)` | `files:write` | Same upload receipt |
| `UploadResourceFile(options)` | `files:write` | Same upload receipt |
| `ListFiles(filters?)` | `files:read` | `files`, `folders`, `pagination` |
| `ListFolders()` | `files:read` | `folders` with counts and sizes |
| `GetFileUrl(fileId)` | `files:read` | `url`, `expires_at` (null for public files) |
| `SetFileVisibility(fileId, private)` | `files:write` | `file` with ID and privacy |
| `DeleteFile(fileId)` | `files:write` | Empty table |
| `DeleteFiles(fileIds)` | `files:write` | `results`, `deleted`, `failed` |
| `DeleteFolder(path, { recursive = true })` | `files:write` | `deleted_objects` |
| `CreateS3Url(options)` | `files:read` or `files:write` | `url`, `method`, `headers`, `expires_at` |

All entries above also expose `Await` variants. Workspace permissions, quotas and account restrictions still apply.

Upload options: `filename` (required), `folder`, `content_type`, `private` (default false). `CreateUploadUrl` also requires an exact positive `size` in bytes. `UploadFile` requires `data` as a binary Lua string; it uses the HTTP method and headers returned by the upload ticket. `UploadJson` requires a serializable table in `data` and sets the content type to JSON.

`UploadResourceFile` takes `path` relative to the invoking resource, optional `resource`, and the normal upload options. A different resource must be explicitly allowed in `fileResources`. No absolute paths or parent traversal are accepted. File content is loaded into memory before its size can be checked, so do not use this for large archives or untrusted paths.

Server body uploads default to at most 8 MiB. A REST ticket is limited by the SDK to 98 MiB for a single request through the upload endpoint. Multipart/chunked uploads are not implemented in this version. A higher storage capacity does not remove those transport limits.

Upload receipts do not contain a file UUID. Use `ListFiles` and match `public_key` to the receipt's `file_key` when you need one. A private receipt's plain CDN URL is not an access grant; request `GetFileUrl` using the file ID. Moderation can remain pending after upload acceptance.

`ListFiles` accepts `folder`, `search`, `access` (`all`, `public`, `private`), `type` (`all`, `image`, `video`, `audio`, `other`), `sort` (`newest`, `oldest`, `name`, `size`), `page` and `limit` (10 to 100). It lists one folder, not every descendant. Pagination is explicit.

`DeleteFiles` accepts 1 to 100 UUIDs. It is sequential and not atomic. Its top-level success means the batch ran; inspect `data.failed` and each `data.results[i].result`. Folder deletion includes descendants and cannot target the root.

S3 options: `key`, `method` (`PUT` by default, or `GET`, `HEAD`, `DELETE`) and optional `expires_in`. BCKT must already have an active S3 credential for the account. The API controls the final expiry, so use `expires_at` from the response. Signing does not perform the operation.

## Logs

| Export | Arguments | Behavior |
| --- | --- | --- |
| `Log` | `stream, event` | Immediately returns queue acceptance |
| `LogBatch` | `stream, events` | Atomically validates and queues 1 to 1000 events |
| `Debug`, `Info`, `Warn`, `Error` | `message, payload?, stream?` | Queues one event; default stream from config |
| `SendLogs` / `SendLogsAwait` | `stream, events` | Sends immediately, without adding to the queue |
| `ListLogStreams` / `ListLogStreamsAwait` | No arguments | Returns `data.streams` |
| `CreateLogStream` / `CreateLogStreamAwait` | `name, slug` | Returns `data.stream` |
| `QueryLogs` / `QueryLogsAwait` | `filters` | Returns the API's events and query metadata |
| `FlushLogs` / `FlushLogsAwait` | No arguments | Sends eligible queued batches; returns acceptance count and queue stats |
| `RetryLogs` | `{ acceptDuplicateRisk = false }?` | Requeues blocked events; uncertain events require explicit opt-in |
| `DiscardLogs` | `{ state = 'blocked', confirm = true }` | Explicitly discards blocked or uncertain events |
| `GetQueueStats` | No arguments | Returns counts and approximate payload bytes |

Use `logs:write` for writing and stream creation, and `logs:read` for querying and listing. Configure `writeResources` to control which local resources can create streams or write events.

An event supports `timestamp` (UTC ISO 8601, defaults to now), `level` (default info), `event_type`, `entity_id` (string), `message` and `payload` (table). The SDK reserves `payload._bckt` for the invoking resource and configured tags. Cfx vectors become coordinate objects. Cycles, unsupported values and excessively deep payloads are rejected. IP addresses and player identifiers are not collected automatically.

Messages are limited to 16000 bytes in the SDK. Events default to at most 64000 encoded bytes. Immediate batches must be under 256000 encoded bytes and contain at most 1000 events. Queued batches are split by stream, event count and encoded size.

`QueryLogs` requires `stream`, `from` and `to`. It also accepts `event_type`, `entity_id`, `search` and `limit` (1 to 1000). The API caps each date range at 31 days. There is no query cursor or arbitrary SQL export.

## Screenshots

`CaptureScreenshot(playerId, options, callback)` and `CaptureScreenshotAwait(playerId, options)` are server exports. Options are `folder` (default screenshots), `private` (default true), `encoding` (jpg, png or webp; default webp) and `quality` (greater than 0 and at most 1; default 0.85).

The `provider` option accepts `auto`, `screenshot-basic` or `screencapture`, and defaults to `BcktConfig.captureProvider` (`auto`). Auto selects a started screenshot-basic first, otherwise screencapture. An explicitly selected resource must be started. Both adapters support JPG, PNG, WebP and quality through `requestScreenshot`. Video and live streaming are not exposed.

Requires one of those capture resources, a connected player and both file scopes. One capture per player can be pending; at most eight globally by default. Capture lifetime defaults to 120 seconds. Success returns `data.file`, `data.url` and `data.expires_at`, verified against the server-side catalog. The server controls the filename and generates a distinct name per capture.

The SDK cannot prove that an image from an untrusted game client is an authentic screenshot. Timeouts and disconnects can leave a successfully uploaded file without a completed callback. No automatic deletion is performed in that case.

## Client image uploads

`UploadImage(ticket, dataUri, callback)` and `UploadImageAwait(ticket, dataUri)` run on the client. Pass `CreateUploadUrl`'s `result.data` as the ticket, not the whole result. Only PNG, JPEG and WebP data URIs are accepted. The current helper caps decoded images at 8 MiB and allows four pending uploads. Tickets must match the exact decoded size.

The helper uses an invisible NUI and never takes keyboard focus. It strips `Content-Length` because the browser manages that header. A phone with its own NUI can upload a Blob directly using the ticket's method and allowed headers.

This helper does not request authorization from the server and does not validate player permissions. Your server integration must do that. Treat its receipt as client input and verify the file on the server before saving it to a player record.

## Status and events

`IsReady()` returns whether a non-empty API key was configured, not whether it is valid. `GetVersion()` returns a string. `GetStatus()` returns readiness, last transport reachability, last request timestamp, last error code and request counts. Reachability does not imply successful authentication.

Local server events: `bckt:ready`, `bckt:requestFailed(details)` and `bckt:queueFull(stats)`. They never carry the API key or signed upload URL. Internal `bckt:capture:*` network events are not a public integration API.
