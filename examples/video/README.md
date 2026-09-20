# Record a clip

Copy this folder as `bckt-video-example`. Start screencapture, bckt and then the example. Use a BCKT key with `files:write` and `files:read`. If you restrict resources in `BcktConfig`, allow `bckt-video-example` in both `allowedResources` and `writeResources`.

The commands work from the server console. To allow your admin group:

```cfg
add_ace group.admin command.bckt-video allow
add_ace group.admin command.bckt-video-stop allow
add_ace group.admin command.bckt-video-cancel allow
add_ace group.admin command.bckt-video-status allow

ensure screencapture
ensure bckt
ensure bckt-video-example
```

```text
bckt-video 12 15
bckt-video-status
bckt-video-stop
```

This records player 12 for up to 15 seconds. Stop finishes and uploads early. `bckt-video-cancel` stops without uploading unless bytes were already being sent. Completed videos appear in `reports/clips`, private by default. The example reports the file ID, without printing its signed access URL.

Recording is handled by screencapture's experimental WebM recorder. Test playback, cancellation and temporary-file cleanup on your game server before enabling it for players. RedM compatibility depends on the installed screencapture build. Live streaming is not part of this example or the BCKT SDK.
