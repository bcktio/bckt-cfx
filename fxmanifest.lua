fx_version 'cerulean'
games { 'gta5', 'rdr3' }
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
author 'BCKT'
description 'Storage, screenshots and structured logs for FiveM and RedM.'
version '0.1.4'
server_scripts { 'server/video.js', 'config.lua', 'server/core.lua', 'server/files.lua', 'server/logs.lua', 'server/capture.lua', 'server/video.lua' }
client_script 'client/main.lua'
ui_page 'web/index.html'
files { 'web/index.html', 'web/main.js' }
