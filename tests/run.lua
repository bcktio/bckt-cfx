local ok, err = xpcall(function() dofile('tests/sdk.lua'); dofile('tests/client.lua') end, debug.traceback)
if not ok then print(err); os.exit(1) end
