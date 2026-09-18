# Console smoke checks

Copy this directory into your resources as `bckt-example`. Start it after bckt. Allow that resource in your SDK allowlists if enabled.

Run these in the server console:

```text
bckt-example-list
bckt-example-log
bckt-example-capture 1
```

Replace 1 with the connected player's server ID. Listing needs files:read, logging needs logs:write, and capture needs files:read and files:write plus screenshot-basic started on the server and available to the player.

Commands refuse in-game callers. The log command creates the server stream if necessary. The capture command stores a private image and prints only its file ID, not its temporary access URL.
