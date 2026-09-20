const fs = require('node:fs');
const path = require('node:path');
const parser = require('luaparse');
const vm = require('node:vm');
let count = 0;
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['.git', 'node_modules', 'dist'].includes(entry.name)) continue;
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(file);
    else if (file.endsWith('.lua')) {
      parser.parse(fs.readFileSync(file, 'utf8'), { luaVersion: '5.3' });
      count++;
    }
  }
}
walk('.');
new vm.Script(fs.readFileSync('web/main.js', 'utf8'));
new vm.Script(fs.readFileSync('server/http.js', 'utf8'));
new vm.Script(fs.readFileSync('server/video.js', 'utf8'));
console.log(`Parsed ${count} Lua files, server transports and the NUI script.`);
