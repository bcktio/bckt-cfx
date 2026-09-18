# Running BCKT on a game server

## Resource permissions

The API key is server-only. Use a dedicated key for each game server, with the smallest necessary scopes. Do not use a dashboard session token.

Empty `allowedResources`, `writeResources` and `deleteResources` lists permit all server resources. Add names to restrict access. For example:

```lua
allowedResources = { 'my-phone', 'my-admin', 'my-economy' },
writeResources = { 'my-phone', 'my-admin', 'my-economy' },
deleteResources = { 'my-admin' },
fileResources = { ['backup-resource'] = true }
```

`allowedResources` applies first, then the operation's write or delete restriction. These lists are server-side guardrails, not a sandbox against malicious resources on your own server. Resource scripts can access server convars. Install only trusted resources.

`fileResources` is a map allowing cross-resource reads. It is empty by default. An invoking resource may read its own relative paths. Do not expose UploadResourceFile or arbitrary paths through a network event.

## Request handling

Defaults are four concurrent HTTP requests, 128 pending requests, a 30-second request deadline and two retries for eligible GET failures. Redirects are disabled. Upload tickets can only target the BCKT upload host. API credentials are not forwarded to it.

A Lua timeout ends the SDK wait but cannot cancel an already-running native HTTP request. Its remote outcome can remain unknown. The concurrency limit controls SDK waits, not cancellation of underlying sockets after a timeout.

The current REST API limits upload ticket creation to 60 requests per 15 minutes per user. Captures and phone uploads share that allowance. Budget automated captures accordingly and handle 429 responses. This SDK does not bypass service rate limits.

GET retry delays are exponential and respect numeric Retry-After values up to 60 seconds. Longer delays are returned to the caller instead of tying up an SDK slot. Writes are not automatically retried by the HTTP layer. Authentication failures and invalid arguments need intervention, not a retry loop.

## Log queue

Defaults: send every five seconds, at most 100 events in a batch, at most 5000 queued events and 8 MiB of approximate encoded payload. A batch contains one stream and at most 256 KB of encoded events.

| State | Meaning | Next action |
| --- | --- | --- |
| pending | Waiting for its first attempt or eligible retry | Background worker sends it |
| sending | Request is in flight | Wait |
| blocked | Definite rejection or retry limit reached | Fix the cause, then RetryLogs |
| uncertain | Request may have been accepted | Investigate before opting into a retry |

Rate-limit responses retry with backoff, honoring numeric Retry-After. After five attempts, the batch is blocked. Other definite rejections remain blocked. A timeout or 5xx on a write is conservatively uncertain.

`RetryLogs()` retries blocked events. `RetryLogs({ acceptDuplicateRisk = true })` also retries uncertain events and may create duplicates. `DiscardLogs({ state = 'uncertain', confirm = true })` permanently removes that state from the local queue. It does not delete logs already stored at BCKT.

Queue-full results reject new events without evicting old ones. Check the result of Log and LogBatch. FlushLogs sends currently eligible batches, not delayed retries; inspect the returned queue stats. A blocked stream does not prevent eligible events from other streams being selected.

Enable `persistLogs` to store the queue in resource KVP storage. Keep the same resource name to retain its KVP namespace. Persistence contains your raw event payloads, is not encrypted and provides no exactly-once guarantee. In-flight saved events become uncertain after restart. A crash between an accepted remote write and local persistence can still produce an uncertain outcome. The resource does not attempt asynchronous HTTP flushing during shutdown.

An unreadable persisted queue disables persistence for that run instead of overwriting the saved value. Inspect and recover it before re-enabling persistence. Do not decrease configured queue limits below a saved backlog without draining it first.

## Direct uploads and screenshots

The server decides who may upload, the folder, privacy, allowed MIME type and maximum size. Never accept those choices wholesale from a player. Limit frequency per player and globally. Do not log tickets or signed links.

Upload tickets are bearer capabilities. This SDK does not promise they are single-use. Expiration does not undo an upload already accepted. Client-side extension or MIME checks alone cannot establish what a file contains.

The screenshot adapter binds each operation to the requesting resource and player, accepts one size declaration, and issues one upload ticket. A unique server-chosen filename allows the server to verify the receipt against the authenticated catalog. No client network event can create a capture operation on its own.

The browser uploads raw bytes. screenshot-basic's own upload export uses multipart, so do not substitute it for this flow. Browser Content-Length is managed automatically. Cloudflare must allow the upload endpoint and preflight OPTIONS through without a browser challenge.

## Local development

```sh
npm ci
npm run check
npm test
```

Development dependencies are only used for local parsing and mocked execution. Tests do not contact BCKT and do not require an API key.

On Windows, `npm run pack:resource` creates `dist/bckt-cfx-0.1.1.zip` with a single `bckt` resource directory. It excludes development dependencies, Git state and test tooling. The shipped resource runs Lua and prewritten browser JavaScript without a build step.

## Before using a release in production

Run these acceptance checks on a staging game server with a dedicated BCKT key:

1. Start bckt on FiveM and RedM and verify the ready event and a file listing.
2. Upload JSON, list its file, switch privacy, retrieve a private link and delete it.
3. Create a stream, send an event, query it and confirm the payload in the dashboard.
4. Install screenshot-basic and capture JPG, PNG and WebP. Confirm filename, size, private access and callback behavior.
5. Upload from the phone example with ACE permission, then verify denial without permission.
6. Disconnect during capture, stop the calling resource, revoke the key, and simulate quota and rate-limit responses.
7. Restart with a persisted queue and verify uncertain events do not resend automatically.

These live checks cannot be replaced by the mocked tests. RedM screenshot capture remains dependent on screenshot-basic's runtime compatibility.
