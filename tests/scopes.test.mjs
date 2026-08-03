import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
});
afterEach(() => lua.global.close());

// A field permitting every settable scope, so precedence can be exercised without
// the scope allowlist getting in the way. Individual tests narrow it.
const FIELD = `
  local field = {
    key = 'nxc_demo.limits.maxItems',
    type = 'integer',
    description = 'demo',
    default = 10,
    validation = { min = 0, max = 1000 },
    scope = { 'environment', 'global', 'resource', 'organization', 'location', 'player' },
    clientVisible = true,
    editCapability = 'config.resource.edit',
    auditClassification = 'operational',
    sensitive = false,
    reloadBehavior = 'Immediate',
    migrationBehavior = 'retain',
    rollbackBehavior = 'restore',
    changeEvent = 'nxc_demo:server:limitsChanged',
  }
`;

describe('Scope precedence', () => {
  test('the ladder is the one the design specifies, lowest first', async () => {
    const r = await lua.doString(`
      return table.concat(NxcConfig.Scopes.ORDER, ' < ')
    `);
    assert.equal(r, 'default < environment < global < resource < organization < location < player');
  });

  test('with nothing published, the schema default wins', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local out = NxcConfig.Scopes.resolve(field, {}, { environment = 'production' })
      return { value = out.value, scope = out.scope }
    `);
    // This is what lets a resource run correctly before nxc_config has said
    // anything to it, which the registration handshake depends on.
    assert.equal(r.value, 10);
    assert.equal(r.scope, 'default');
  });

  test('a higher scope beats a lower one regardless of order supplied', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local records = {
        { key = field.key, scope = 'player', scopeId = 'p1', value = 4 },
        { key = field.key, scope = 'global', value = 2 },
        { key = field.key, scope = 'environment', scopeId = 'production', value = 1 },
      }
      local out = NxcConfig.Scopes.resolve(field, records,
        { environment = 'production', player = 'p1' })
      return { value = out.value, scope = out.scope, overridden = #out.overridden }
    `);
    assert.equal(r.value, 4, 'player preference is the top of the ladder');
    assert.equal(r.scope, 'player');
    assert.equal(r.overridden, 2);
  });

  test('resource beats global, which is the one people get backwards', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local records = {
        { key = field.key, scope = 'resource', scopeId = 'nxc_demo', value = 7 },
        { key = field.key, scope = 'global', value = 3 },
      }
      local out = NxcConfig.Scopes.resolve(field, records, { resource = 'nxc_demo' })
      return { value = out.value, scope = out.scope }
    `);
    assert.equal(r.value, 7);
    assert.equal(r.scope, 'resource');
  });

  test('a value for another subject does not apply', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local records = {
        { key = field.key, scope = 'player', scopeId = 'someone_else', value = 99 },
      }
      local out = NxcConfig.Scopes.resolve(field, records, { player = 'me' })
      return { value = out.value, scope = out.scope }
    `);
    assert.equal(r.value, 10, 'another player\'s preference is not mine');
    assert.equal(r.scope, 'default');
  });

  test('an identified scope sits out a resolution that does not name a subject', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local records = {
        { key = field.key, scope = 'organization', scopeId = 'org_a', value = 50 },
        { key = field.key, scope = 'global', value = 3 },
      }
      -- A server-wide question, asked without an organization in context.
      local out = NxcConfig.Scopes.resolve(field, records, {})
      return { value = out.value, scope = out.scope }
    `);
    assert.equal(r.value, 3);
    assert.equal(r.scope, 'global');
  });

  test('a value at a scope the field forbids is ignored', async () => {
    const r = await lua.doString(`
      ${FIELD}
      field.scope = { 'global' }
      local records = {
        { key = field.key, scope = 'player', scopeId = 'p1', value = 99 },
        { key = field.key, scope = 'global', value = 3 },
      }
      local out = NxcConfig.Scopes.resolve(field, records, { player = 'p1' })
      return { value = out.value, scope = out.scope }
    `);
    // A field scoped global-only that resolved per player would mean different
    // players seeing different values for a setting whose author said it must
    // not vary. Ignored at resolution as well as refused at write.
    assert.equal(r.value, 3);
    assert.equal(r.scope, 'global');
  });

  test('a later record at the same scope wins, because it is the newer publication', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local records = {
        { key = field.key, scope = 'global', value = 1 },
        { key = field.key, scope = 'global', value = 2 },
      }
      local out = NxcConfig.Scopes.resolve(field, records, {})
      return out.value
    `);
    assert.equal(r, 2);
  });

  test('resolution reports what was overridden, so a screen can explain itself', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local records = {
        { key = field.key, scope = 'global', value = 3 },
        { key = field.key, scope = 'player', scopeId = 'p1', value = 8 },
      }
      local out = NxcConfig.Scopes.resolve(field, records, { player = 'p1' })
      return {
        winner = out.scope,
        lostScope = out.overridden[1].scope,
        lostValue = out.overridden[1].value,
      }
    `);
    assert.equal(r.winner, 'player');
    assert.equal(r.lostScope, 'global');
    assert.equal(r.lostValue, 3);
  });
});

describe('Scope validation', () => {
  test('an identified scope requires a subject', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local ok, reason = NxcConfig.Scopes.validateRecord(field, { scope = 'organization' })
      return { ok = ok, reason = reason }
    `);
    assert.equal(r.ok, false, 'a value for no particular organization resolves for everyone');
    assert.match(r.reason, /requires a scopeId/);
  });

  test('an unidentified scope refuses a subject', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local ok, reason = NxcConfig.Scopes.validateRecord(field,
        { scope = 'global', scopeId = 'org_a' })
      return { ok = ok, reason = reason }
    `);
    // Ignoring it would store a value that looks targeted, is not, and reads in
    // the audit log as though it were.
    assert.equal(r.ok, false);
    assert.match(r.reason, /takes no scopeId/);
  });

  test('the default scope cannot be written to', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local ok, reason = NxcConfig.Scopes.permits(field, 'default')
      return { ok = ok, reason = reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /comes from the schema/);
  });

  test('an unknown scope is refused by name', async () => {
    const r = await lua.doString(`
      ${FIELD}
      local ok, reason = NxcConfig.Scopes.permits(field, 'galaxy')
      return { ok = ok, reason = reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /unknown scope: galaxy/);
  });
});

describe('Client view', () => {
  test('a sensitive field never reaches a client, whatever else it says', async () => {
    const r = await lua.doString(`
      local fields = {
        { key = 'a.b.c', clientVisible = true,  sensitive = false },
        { key = 'a.b.secret', clientVisible = true,  sensitive = true },
        { key = 'a.b.internal', clientVisible = false, sensitive = false },
      }
      local values = { ['a.b.c'] = 1, ['a.b.secret'] = 2, ['a.b.internal'] = 3 }
      local view = NxcConfig.Scopes.clientView(fields, values)
      local n = 0
      for _ in pairs(view) do n = n + 1 end
      return { count = n, visible = view['a.b.c'],
               secret = view['a.b.secret'], internal = view['a.b.internal'] }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.visible, 1);
    // Two separate flags for two separate reasons: sensitive means disclosure is
    // harmful, not-client-visible means the client has no business knowing.
    assert.equal(r.secret, undefined, 'a sensitive field marked client-visible is a contradiction');
    assert.equal(r.internal, undefined);
  });
});

describe('Resolving a whole schema', () => {
  test('every field resolves in one pass', async () => {
    const r = await lua.doString(`
      local fields = {
        { key = 'r.a.one', default = 1, scope = { 'global' } },
        { key = 'r.a.two', default = 2, scope = { 'global' } },
        { key = 'r.a.three', default = 3, scope = { 'global' } },
      }
      local records = {
        { key = 'r.a.one', scope = 'global', value = 100 },
        { key = 'r.a.three', scope = 'global', value = 300 },
      }
      local values, detail = NxcConfig.Scopes.resolveAll(fields, records, {})
      return {
        one = values['r.a.one'], two = values['r.a.two'], three = values['r.a.three'],
        twoScope = detail['r.a.two'].scope,
      }
    `);
    assert.equal(r.one, 100);
    assert.equal(r.two, 2, 'an unpublished field still resolves, to its default');
    assert.equal(r.three, 300);
    assert.equal(r.twoScope, 'default');
  });
});
