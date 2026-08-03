import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

const VALID = `
  function makeField(overrides)
    local f = {
      key = 'nxc_demo.limits.maxItems',
      type = 'integer',
      description = 'How many items may be held.',
      default = 10,
      validation = { min = 0, max = 1000 },
      scope = { 'global', 'resource' },
      clientVisible = true,
      editCapability = 'config.resource.edit',
      auditClassification = 'operational',
      sensitive = false,
      reloadBehavior = 'Immediate',
      migrationBehavior = 'retain',
      rollbackBehavior = 'restore',
      changeEvent = 'nxc_demo:server:limitsChanged',
    }
    for k, v in pairs(overrides or {}) do f[k] = v end
    return f
  end
`;

describe('Schema registration', () => {
  test('a well-formed schema registers', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo', { makeField() })
      local reason
      if not out.ok then reason = out.error.details.fields[1].reason end
      -- Written as separate statements rather than the and/or idiom: that form
      -- yields nil whenever the middle value is false, which is exactly what
      -- replaced is here. The same trap was already fixed once in nxc_core's
      -- services module. It reads correctly and is wrong.
      return {
        ok = out.ok,
        reason = reason,
        count = out.value and out.value.fieldCount,
        replaced = out.value and out.value.replaced,
      }
    `);
    assert.equal(r.ok, true, r.reason);
    assert.equal(r.count, 1);
    assert.equal(r.replaced, false);
  });

  test('a key must be namespaced to the registering resource', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo',
        { makeField({ key = 'nxc_banking.limits.maxItems' }) })
      local reasons = {}
      for _, p in ipairs(out.error.details.fields) do reasons[#reasons + 1] = p.reason end
      return { ok = out.ok, reasons = table.concat(reasons, ' | ') }
    `);
    // Without this a resource could register a key belonging to another and
    // quietly shadow it.
    assert.equal(r.ok, false);
    assert.match(r.reasons, /must begin with nxc_demo\./);
  });

  test('every required property is enforced', async () => {
    const r = await lua.doString(`
      ${VALID}
      local bare = { key = 'nxc_demo.a.b' }
      local out = NxcConfig.Registry.register('nxc_demo', { bare })
      return { ok = out.ok, count = #out.error.details.fields }
    `);
    assert.equal(r.ok, false);
    // Thirteen missing properties, plus the invalid scope list.
    assert.ok(r.count >= 13, `expected many problems, got ${r.count}`);
  });

  test('a sensitive field cannot be client-visible', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo',
        { makeField({ sensitive = true, clientVisible = true }) })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /cannot be client-visible/);
  });

  test('a default its own validation would reject is refused', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo',
        { makeField({ default = 5000 }) })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    // Otherwise the resource starts on a value its own management screen rejects.
    assert.equal(r.ok, false);
    assert.match(r.reason, /declared default is invalid/);
  });

  test('an unsettable scope is refused', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo',
        { makeField({ scope = { 'default' } }) })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /not a settable scope/);
  });

  test('unknown enumerations are named, not shrugged at', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo', {
        makeField({ key = 'nxc_demo.a.one', type = 'colour' }),
        makeField({ key = 'nxc_demo.a.two', reloadBehavior = 'Whenever' }),
        makeField({ key = 'nxc_demo.a.three', auditClassification = 'vibes' }),
      })
      local reasons = {}
      for _, p in ipairs(out.error.details.fields) do reasons[#reasons + 1] = p.reason end
      return table.concat(reasons, ' | ')
    `);
    assert.match(r, /unknown type colour/);
    assert.match(r, /unknown reload behavior Whenever/);
    assert.match(r, /unknown audit classification vibes/);
  });

  test('a duplicate key is caught', async () => {
    const r = await lua.doString(`
      ${VALID}
      local out = NxcConfig.Registry.register('nxc_demo', { makeField(), makeField() })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /duplicate key/);
  });

  test('a rejected schema stores nothing at all', async () => {
    const r = await lua.doString(`
      ${VALID}
      NxcConfig.Registry.register('nxc_demo', {
        makeField({ key = 'nxc_demo.a.good' }),
        makeField({ key = 'nxc_demo.a.bad', type = 'colour' }),
      })
      return NxcConfig.Registry.isRegistered('nxc_demo')
    `);
    // A partial schema is worse than none: the resource runs believing it
    // registered, and half its settings are unmanageable with no error anywhere.
    assert.equal(r, false);
  });

  test('re-registration replaces, and reports what disappeared', async () => {
    const r = await lua.doString(`
      ${VALID}
      NxcConfig.Registry.register('nxc_demo', {
        makeField({ key = 'nxc_demo.a.kept' }),
        makeField({ key = 'nxc_demo.a.dropped' }),
      })
      local out = NxcConfig.Registry.register('nxc_demo', {
        makeField({ key = 'nxc_demo.a.kept' }),
        makeField({ key = 'nxc_demo.a.added' }),
      })
      return {
        replaced = out.value.replaced,
        removed = table.concat(out.value.removedKeys, ','),
        count = #NxcConfig.Registry.fields('nxc_demo'),
      }
    `);
    // The new declaration is the running code, so it is authoritative. Merging
    // would leave fields belonging to a version nobody is running.
    assert.equal(r.replaced, true);
    assert.equal(r.removed, 'nxc_demo.a.dropped');
    assert.equal(r.count, 2);
  });

  test('a field is findable by key, with its owner', async () => {
    const r = await lua.doString(`
      ${VALID}
      NxcConfig.Registry.register('nxc_demo', { makeField() })
      local field, owner = NxcConfig.Registry.field('nxc_demo.limits.maxItems')
      local missing = NxcConfig.Registry.field('nxc_demo.limits.nope')
      return { key = field.key, owner = owner, missing = missing }
    `);
    assert.equal(r.key, 'nxc_demo.limits.maxItems');
    assert.equal(r.owner, 'nxc_demo');
    assert.equal(r.missing, undefined);
  });

  test('registered resources are listed in a stable order', async () => {
    const r = await lua.doString(`
      ${VALID}
      NxcConfig.Registry.register('nxc_zulu', { makeField({ key = 'nxc_zulu.a.b' }) })
      NxcConfig.Registry.register('nxc_alpha', { makeField({ key = 'nxc_alpha.a.b' }) })
      return table.concat(NxcConfig.Registry.resources(), ',')
    `);
    assert.equal(r, 'nxc_alpha,nxc_zulu');
  });
});

describe('Value checking', () => {
  test('type, range, pattern, and enumeration are all enforced', async () => {
    const r = await lua.doString(`
      ${VALID}
      local int = makeField()
      local text = makeField({ type = 'string', default = 'a', validation = { pattern = '^%a+$' } })
      local pick = makeField({ type = 'string', default = 'red',
                               validation = { oneOf = { 'red', 'blue' } } })
      local flag = makeField({ type = 'boolean', default = true, validation = {} })

      local function reason(f, v)
        local ok, why = NxcConfig.Registry.checkValue(f, v)
        return ok and 'ok' or why
      end

      return {
        fraction = reason(int, 2.5),
        low      = reason(int, -1),
        high     = reason(int, 9999),
        good     = reason(int, 500),
        badText  = reason(text, 'has spaces'),
        badPick  = reason(pick, 'green'),
        badFlag  = reason(flag, 'yes'),
      }
    `);
    assert.match(r.fraction, /whole number/);
    assert.match(r.low, /at least 0/);
    assert.match(r.high, /at most 1000/);
    assert.equal(r.good, 'ok');
    assert.match(r.badText, /expected format/);
    assert.match(r.badPick, /must be one of: red, blue/);
    assert.match(r.badFlag, /must be a boolean/);
  });

  test('the real nxc_core schema registers unchanged', async () => {
    const r = await lua.doString(`
      -- nxc_core's own schema, which nxc_config has never seen. If the two
      -- disagree about what a field looks like, this is where it shows.
      local fields = {
        {
          key = 'nxc_core.characters.maxPerAccount',
          type = 'integer',
          description = 'How many characters one account may hold.',
          default = 5,
          validation = { min = 1, max = 20 },
          scope = { 'global', 'environment' },
          clientVisible = true,
          editCapability = 'config.resource.publish',
          auditClassification = 'operational',
          sensitive = false,
          reloadBehavior = 'Immediate',
          migrationBehavior = 'retain',
          rollbackBehavior = 'restore',
          changeEvent = 'nxc_core:server:characterPolicyChanged',
        },
        {
          key = 'nxc_core.migrations.applyOnStart',
          type = 'boolean',
          description = 'Whether pending migrations are applied at startup.',
          default = true,
          validation = {},
          scope = { 'global', 'environment' },
          clientVisible = false,
          editCapability = 'config.resource.publish',
          auditClassification = 'security',
          sensitive = false,
          reloadBehavior = 'Resource Restart Required',
          migrationBehavior = 'retain',
          rollbackBehavior = 'restore',
          changeEvent = 'nxc_core:server:migrationPolicyChanged',
        },
      }
      local out = NxcConfig.Registry.register('nxc_core', fields)
      local reasons = {}
      if not out.ok then
        for _, p in ipairs(out.error.details.fields) do reasons[#reasons + 1] = p.reason end
      end
      return { ok = out.ok, reasons = table.concat(reasons, ' | ') }
    `);
    assert.equal(r.ok, true, `nxc_core's schema was rejected: ${r.reasons}`);
  });
});
