# A photo from your phone UI to BCKT

Copy this directory into your server resources as `bckt-phone-example`. It is a separate resource, not loaded automatically by bckt. Start it after bckt.

Use a BCKT key with both `files:write` and `files:read`. If you configured resource allowlists, allow `bckt-phone-example` to read and write.

For a test administrator group:

```cfg
add_ace group.admin bckt.example.phone allow
ensure bckt
ensure bckt-phone-example
```

Your test player must actually belong to that ACE group. For a real phone, replace or extend the ACE check with your server-side character, phone ownership and account rules. This example deliberately does not authorize everyone by default.

From your phone's client Lua, after obtaining an image data URI from its UI:

```lua
exports['bckt-phone-example']:UploadPhoneImage(dataUri, function(result)
    if not result.success then
        print(result.error.message)
        return
    end

    local photoUrl = result.data.url
    print(photoUrl)
end)
```

The example sends the size and MIME type to the server, not the image bytes. The server picks the folder and unique filename, enforces a per-player cooldown, caps active uploads and creates the ticket. The client uploads through the SDK's invisible NUI. The server then verifies the returned file key, filename, size, MIME and public visibility against BCKT's catalog.

For database writes, listen to the local server event `bckt-phone:verified(playerId, file)`. Associate the current server-side character with `file.id` there. Do not let a client provide an arbitrary photo URL to save. Recheck character identity if a player can switch characters while an upload is pending.

Photos in this example are public. If your product needs private photos, change the server's ticket privacy, verify that setting, and obtain an access URL from GetFileUrl. Do not save an expiring URL as a permanent identifier; save the file ID.

This resource provides the integration flow, not a phone UI or a database schema. It does not bypass file moderation and does not prove the content of the image from its MIME label.
