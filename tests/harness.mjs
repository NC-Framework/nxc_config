/**
 * Test harness for nxc_config: loads the shared Lua modules into a Lua 5.4
 * engine running under WebAssembly, so pure-logic modules are testable without
 * the FiveM runtime.
 *
 * Identical in shape to nxc_lib's and nxc_core's, and identical on purpose:
 * a harness that differs per resource is a harness whose differences nobody
 * remembers.
 *
 * This is why modules must call no natives. wasmoon provides Lua, not FiveM —
 * there is no GetPlayerPed and no TriggerClientEvent. Any logic entangled with a
 * native is untestable here and belongs in a separate module.
 *
 * THE LOAD ORDER COMES FROM `fxmanifest.lua`, NOT FROM THIS FILE.
 *
 * It used to read the shared directory and sort alphabetically, which worked
 * only because the filenames carried numeric prefixes. Those prefixes are gone —
 * they are not how FiveM resources are normally written — so the manifest
 * enumerates the load order instead, and this reads it from there.
 *
 * Which means the tests exercise the same declaration the server does. Reorder
 * the manifest wrongly and the suite fails here rather than on deployment.

 *
 * ONE ENGINE PER TEST, NOT PER FILE. wasmoon 1.16.0 leaks on every `doString`,
 * and an engine stops working after roughly sixty of them: Lua starts reporting
 * `_ENV` as nil, or closing the state faults with an out-of-bounds access. This
 * is reproducible on a bare engine with no Nexus code loaded at all, so it is a
 * property of the runner rather than anything the framework does.
 *
 * Loading the shared modules already spends about half that budget, which left
 * the previous per-file engine sitting just under the limit — the suite passed
 * until one more test file was added, and then unrelated files began failing at
 * teardown. An engine per test costs about thirteen milliseconds and removes the
 * cliff entirely.
 */

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LuaFactory } from 'wasmoon';

const here = dirname(fileURLToPath(import.meta.url));
const resourceRoot = resolve(here, '..');
const workspace = resolve(resourceRoot, '..');

/**
 * Expand one `shared_scripts` entry into absolute file paths.
 *
 * `@other_resource/path` resolves into the sibling checkout, which is what the
 * server does with another resource's files. A bare path resolves locally. Both
 * support a `*` glob in the final segment.
 */
function expand(entry) {
  let base = resourceRoot;
  let rel = entry;

  const external = entry.match(/^@([\w-]+)\/(.+)$/);
  if (external) {
    base = resolve(workspace, external[1]);
    rel = external[2];
  }

  const slash = rel.lastIndexOf('/');
  const dir = resolve(base, slash === -1 ? '' : rel.slice(0, slash));
  const leaf = slash === -1 ? rel : rel.slice(slash + 1);

  if (!leaf.includes('*')) return [join(dir, leaf)];

  const re = new RegExp('^' + leaf.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
  return readdirSync(dir).filter((f) => re.test(f)).sort().map((f) => join(dir, f));
}

/** Every shared script this resource declares, in declared order. */
function declaredSharedScripts() {
  const manifest = readFileSync(join(resourceRoot, 'fxmanifest.lua'), 'utf8');
  const block = manifest.match(/shared_scripts\s*\{([\s\S]*?)\n\}/);
  if (!block) throw new Error('fxmanifest.lua declares no shared_scripts block');
  const entries = [...block[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  if (!entries.length) throw new Error('shared_scripts block is empty');
  return entries.flatMap(expand);
}

/**
 * Create an engine with every shared module loaded.
 *
 * A fresh engine per test also keeps state isolated: a test that depends on
 * another test having run is a test that fails when run alone.
 */
/**
 * Enough CitizenFX for a module to LOAD. Not enough to certify anything.
 *
 * nxc_lib's `service_client.lua` is server-only and guards itself with
 * `IsDuplicityVersion()`, which does not exist in plain Lua. Without these, every
 * test in this suite failed on a shared file none of them were testing.
 *
 * THE SCOPE IS DELIBERATELY LOAD TIME. `CreateThread` is a no-op, so a body
 * scheduled onto a thread never runs here, and nothing that depends on one
 * should be read as tested. Cross-boundary behaviour is covered in nxc_lib's
 * boundary harness against two real Lua states.
 */
const CITIZEN_LOAD_STUBS = `
    function exports() end
    function IsDuplicityVersion() return true end
    function GetCurrentResourceName() return 'nxc_config' end
    function GetInvokingResource() return nil end
    function GetResourceState() return 'started' end
    function GetResourceMetadata(_, key)
        if key == 'version' then return '0.0.0-test' end
        return nil
    end
    function CreateThread() end
    function Wait() end
    __gameTimerMs = 0
    function GetGameTimer() __gameTimerMs = __gameTimerMs + 16 return __gameTimerMs end
`;

export async function createEngine() {
  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  await lua.doString(CITIZEN_LOAD_STUBS);

  for (const file of declaredSharedScripts()) {
    const source = readFileSync(file, 'utf8');
    try {
      await lua.doString(source);
    } catch (err) {
      throw new Error(`failed loading ${file}: ${err.message}`);
    }
  }

  return lua;
}

/**
 * Run a Lua snippet and return its value.
 *
 * The snippet body is wrapped so `return` works directly.
 */
export async function evalLua(lua, source) {
  return lua.doString(source);
}

/**
 * Load the engine, run a snippet, close the engine.
 *
 * Closing matters: each engine holds a WASM instance, and a suite that leaks
 * them exhausts memory long before it finishes.
 */
export async function withLua(fn) {
  const lua = await createEngine();
  try {
    return await fn(lua);
  } finally {
    lua.global.close();
  }
}

/**
 * Install a deterministic clock.
 *
 * Returns a controller so a test can advance time explicitly. A test that waits
 * for real time is slow; one that depends on real time is flaky.
 */
export async function withFrozenClock(lua, startMs = 1_700_000_000_000) {
  await lua.doString(`
    __testClockMs = ${startMs}
    Nxc.Time.setClock(function() return __testClockMs end)
  `);
  return {
    async advance(ms) {
      await lua.doString(`__testClockMs = __testClockMs + ${ms}`);
    },
    async set(ms) {
      await lua.doString(`__testClockMs = ${ms}`);
    },
  };
}
