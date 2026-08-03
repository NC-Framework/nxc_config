import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LuaFactory } from 'wasmoon';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');

/**
 * Every Lua file in the resource, including the ones the harness never loads.
 *
 * `shared/` is exercised by every other suite. `server/` is not, and cannot be:
 * it calls natives that exist only inside FiveM. Until now that meant a syntax
 * error is found by the server, on a real deployment.
 *
 * It earned its place immediately: the first file written in this resource after
 * the suite was added had a stray brace, and this is what said so.
 *
 * Compiling is not running. `load` parses and produces a function; nothing calls
 * it, so `IsDuplicityVersion` and `exports.oxmysql` are never reached. That is
 * exactly the coverage that was missing: it proves the file is well-formed Lua
 * without needing the platform it targets.
 *
 * It does NOT prove the file works. A typo in a native's name compiles fine.
 */
function luaFiles(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.git' || name === 'tests') continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) luaFiles(full, out);
    else if (name.endsWith('.lua')) out.push(full);
  }
  return out;
}

describe('Lua syntax', () => {
  test('every Lua file in the resource compiles under Lua 5.4', async () => {
    const files = luaFiles(root);
    assert.ok(files.length > 0, 'found no Lua files, which means this test is checking nothing');

    const factory = new LuaFactory();
    const lua = await factory.createEngine();
    const failures = [];

    try {
      // Compile in Lua rather than executing: `load` returns nil plus a message
      // on a syntax error, and never runs the chunk.
      for (const file of files) {
        const rel = relative(root, file).replace(/\\/g, '/');
        await lua.global.set('__source', readFileSync(file, 'utf8'));
        await lua.global.set('__name', rel);
        const err = await lua.doString(`
          local chunk, message = load(__source, '@' .. __name)
          if chunk then return nil end
          return message
        `);
        if (err) failures.push(String(err));
      }
    } finally {
      lua.global.close();
    }

    assert.deepEqual(failures, [], `Lua files failed to compile:\n  ${failures.join('\n  ')}`);
  });

  test('the sweep is actually finding files', async () => {
    // Guards the test above against quietly checking nothing. A sweep that finds
    // no files passes, and the one thing this suite exists for would be gone with
    // no failure anywhere.
    const files = luaFiles(root).map((f) => relative(root, f).split('\\').join('/'));
    assert.ok(files.length >= 3, `expected several Lua files, found ${files.length}`);
    assert.ok(files.some((f) => f.startsWith('shared/')), 'no shared/ files found');
  });
});
