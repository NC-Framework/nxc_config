import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine, withFrozenClock } from './harness.mjs';

let lua;
beforeEach(async () => {
  lua = await createEngine();
  await withFrozenClock(lua, 1700000000000);
  await lua.doString(SETUP);
});
afterEach(() => lua.global.close());

// A registered resource with three fields covering the cases that matter:
// an immediate integer, a restart-required boolean, and a sensitive string.
const SETUP = `
  NxcConfig.Registry.reset()
  NxcConfig.Registry.register('nxc_demo', {
    {
      key = 'nxc_demo.limits.maxItems', type = 'integer',
      description = 'How many items may be held.', default = 10,
      validation = { min = 0, max = 1000 },
      scope = { 'global', 'resource', 'organization' },
      clientVisible = true, editCapability = 'config.resource.edit',
      auditClassification = 'operational', sensitive = false,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'nxc_demo:server:limitsChanged',
    },
    {
      key = 'nxc_demo.startup.eager', type = 'boolean',
      description = 'Whether to do the thing at startup.', default = false,
      validation = {},
      scope = { 'global' },
      clientVisible = false, editCapability = 'config.resource.publish',
      auditClassification = 'operational', sensitive = false,
      reloadBehavior = 'Resource Restart Required', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'nxc_demo:server:startupChanged',
    },
    {
      key = 'nxc_demo.integration.webhook', type = 'string',
      description = 'Where notifications are posted.', default = '',
      validation = {},
      scope = { 'global', 'organization' },
      clientVisible = false, editCapability = 'config.resource.publish',
      auditClassification = 'security', sensitive = true,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'nxc_demo:server:webhookChanged',
    },
  })
  store = NxcConfig.Store.inMemory()
`;

describe('Draft validation', () => {
  test('a valid draft is accepted', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({
        resource = 'nxc_demo', actor = 'acc_admin',
        entries = { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } },
      })
      local reason
      if not out.ok then reason = out.error.details.fields[1].reason end
      return { ok = out.ok, reason = reason, count = out.value and #out.value.entries }
    `);
    assert.equal(r.ok, true, r.reason);
    assert.equal(r.count, 1);
  });

  test('an unregistered key is refused, not stored for later', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = { { key = 'nxc_demo.limits.nonsense', scope = 'global', value = 1 } },
      })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    // Nothing resolves it and nothing validates it, so it would sit in the store
    // looking like configuration.
    assert.equal(r.ok, false);
    assert.match(r.reason, /not a registered setting/);
  });

  test('a resource cannot draft a change to another resource\'s setting', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({
        resource = 'nxc_banking',
        entries = { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } },
      })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /belongs to nxc_demo, not nxc_banking/);
  });

  test('every problem is reported at once', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = {
          { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 99999 },
          { key = 'nxc_demo.startup.eager', scope = 'player', scopeId = 'p1', value = true },
          { key = 'nxc_demo.limits.maxItems', scope = 'organization', value = 5 },
        },
      })
      local reasons = {}
      for _, p in ipairs(out.error.details.fields) do reasons[#reasons + 1] = p.reason end
      return { ok = out.ok, count = #reasons, all = table.concat(reasons, ' | ') }
    `);
    assert.equal(r.ok, false);
    // Out of range; a scope the field forbids; an identified scope with no id.
    assert.equal(r.count, 3, r.all);
    assert.match(r.all, /at most 1000/);
    assert.match(r.all, /not one of this field's scopes/);
    assert.match(r.all, /requires a scopeId/);
  });

  test('setting one key twice at one scope in a draft is refused', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = {
          { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 1 },
          { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 2 },
        },
      })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    // Whichever won would do so by list position, which is not a decision anyone
    // made.
    assert.equal(r.ok, false);
    assert.match(r.reason, /set twice at the same scope/);
  });

  test('an empty draft is refused', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({ resource = 'nxc_demo', entries = {} })
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    assert.equal(r.ok, false);
    assert.match(r.reason, /must change something/);
  });

  test('the same key at two different scopes is fine', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = {
          { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 20 },
          { key = 'nxc_demo.limits.maxItems', scope = 'organization',
            scopeId = 'org_a', value = 50 },
        },
      })
      return { ok = out.ok, count = #out.value.entries }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.count, 2);
  });
});

describe('Impact preview', () => {
  test('a first-time value previews as coming from nothing', async () => {
    const r = await lua.doString(`
      local draft = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } },
      }).value
      local out = NxcConfig.Drafts.preview(draft, store).value
      local c = out.changes[1]
      return { count = #out.changes, from = c.from, to = c.to, state = c.fromState }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.from, undefined);
    assert.equal(r.to, 25);
    assert.match(r.state, /not set at this scope/);
  });

  test('a preview compares against the value in force at that scope', async () => {
    const r = await lua.doString(`
      store.appendValues({
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
      })
      local draft = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 40 } },
      }).value
      local c = NxcConfig.Drafts.preview(draft, store).value.changes[1]
      return { from = c.from, to = c.to }
    `);
    assert.equal(r.from, 25);
    assert.equal(r.to, 40);
  });

  test('publishing the value already in force is reported, not silently dropped', async () => {
    const r = await lua.doString(`
      store.appendValues({
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
      })
      local draft = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } },
      }).value
      local out = NxcConfig.Drafts.preview(draft, store).value
      return { changes = #out.changes, unchanged = #out.unchanged, noOp = out.isNoOp }
    `);
    // Discarding it silently would hide that the operator did something; keeping
    // it as a change would write an audit record saying nothing happened.
    assert.equal(r.changes, 0);
    assert.equal(r.unchanged, 1);
    assert.equal(r.noOp, true);
  });

  test('a restart requirement is surfaced BEFORE publishing', async () => {
    const r = await lua.doString(`
      local draft = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = {
          { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 30 },
          { key = 'nxc_demo.startup.eager', scope = 'global', value = true },
        },
      }).value
      local out = NxcConfig.Drafts.preview(draft, store).value
      return {
        requiresRestart = out.requiresRestart,
        restart = table.concat(out.restartKeys, ','),
        immediate = table.concat(out.immediateKeys, ','),
      }
    `);
    // Publishing and then discovering this is how a server gets restarted during
    // peak hours.
    assert.equal(r.requiresRestart, true);
    assert.equal(r.restart, 'nxc_demo.startup.eager');
    assert.equal(r.immediate, 'nxc_demo.limits.maxItems');
  });

  test('a preview carries the audit classification and the sensitive flag', async () => {
    const r = await lua.doString(`
      local draft = NxcConfig.Drafts.create({
        resource = 'nxc_demo',
        entries = { { key = 'nxc_demo.integration.webhook', scope = 'global',
                      value = 'https://example.invalid/hook' } },
      }).value
      local c = NxcConfig.Drafts.preview(draft, store).value.changes[1]
      return { sensitive = c.sensitive, classification = c.auditClassification }
    `);
    assert.equal(r.sensitive, true);
    assert.equal(r.classification, 'security');
  });
});

describe('Store', () => {
  test('values come back in publication order', async () => {
    const r = await lua.doString(`
      store.appendValues({
        { key = 'k', scope = 'global', value = 1 },
        { key = 'k', scope = 'global', value = 2 },
        { key = 'k', scope = 'global', value = 3 },
      })
      local rows = store.values({ key = 'k' })
      return { count = #rows, first = rows[1].value, last = rows[#rows].value }
    `);
    // Resolution treats a later record at the same scope as the newer
    // publication, so unordered reads would resolve non-deterministically.
    assert.equal(r.count, 3);
    assert.equal(r.first, 1);
    assert.equal(r.last, 3);
  });

  test('publications come back newest first', async () => {
    const r = await lua.doString(`
      store.appendPublication({ id = 'pub_1', resource = 'nxc_demo' })
      store.appendPublication({ id = 'pub_2', resource = 'nxc_demo' })
      store.appendPublication({ id = 'pub_3', resource = 'other' })
      local all = store.publications()
      local mine = store.publications('nxc_demo')
      return { firstAll = all[1].id, mineCount = #mine, mineFirst = mine[1].id }
    `);
    // Every caller wants the recent ones; reversing per call site is how one of
    // them ends up not doing it.
    assert.equal(r.firstAll, 'pub_3');
    assert.equal(r.mineCount, 2);
    assert.equal(r.mineFirst, 'pub_2');
  });

  test('a publication is findable by its idempotency key', async () => {
    const r = await lua.doString(`
      store.appendPublication({ id = 'pub_1', idempotencyKey = 'abc' })
      local found = store.publicationByIdempotencyKey('abc')
      local missing = store.publicationByIdempotencyKey('nope')
      return { found = found and found.id, missing = missing }
    `);
    assert.equal(r.found, 'pub_1');
    assert.equal(r.missing, undefined);
  });
});
