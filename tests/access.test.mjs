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

const SETUP = `
  NxcConfig.Registry.reset()
  NxcConfig.Registry.register('nxc_demo', {
    {
      key = 'nxc_demo.limits.maxItems', type = 'integer', description = 'd',
      default = 10, validation = { min = 0, max = 1000 },
      scope = { 'global', 'organization' },
      clientVisible = true, editCapability = 'config.resource.edit',
      auditClassification = 'operational', sensitive = false,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'e',
    },
    {
      key = 'nxc_demo.startup.eager', type = 'boolean', description = 'd',
      default = false, validation = {}, scope = { 'global' },
      clientVisible = false, editCapability = 'config.resource.publish',
      auditClassification = 'operational', sensitive = false,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'e',
    },
    {
      key = 'nxc_demo.integration.webhook', type = 'string', description = 'd',
      default = '', validation = {}, scope = { 'global' },
      clientVisible = false, editCapability = 'config.resource.publish',
      auditClassification = 'security', sensitive = true,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'e',
    },
  })

  function draftOf(entries)
    return NxcConfig.Drafts.create({ resource = 'nxc_demo', entries = entries }).value
  end
`;

describe('Capability checks', () => {
  test('a capability may be held as a list or a set', async () => {
    const r = await lua.doString(`
      local A = NxcConfig.Access
      return {
        fromList = A.holds({ 'config.resource.edit' }, 'config.resource.edit'),
        fromSet  = A.holds({ ['config.resource.edit'] = true }, 'config.resource.edit'),
        absent   = A.holds({ 'config.resource.view' }, 'config.resource.edit'),
      }
    `);
    // Callers naturally produce lists. Quietly returning false for one would be a
    // permission bug that reads as a policy decision.
    assert.equal(r.fromList, true);
    assert.equal(r.fromSet, true);
    assert.equal(r.absent, false);
  });

  test('a resource-scoped capability grants nothing elsewhere', async () => {
    const r = await lua.doString(`
      local A = NxcConfig.Access
      local held = { 'config.resource.edit:nxc_demo' }
      return {
        own    = A.holds(held, 'config.resource.edit', 'nxc_demo'),
        other  = A.holds(held, 'config.resource.edit', 'nxc_banking'),
        global = A.holds(held, 'config.resource.edit'),
      }
    `);
    // The entire point of the narrow form.
    assert.equal(r.own, true);
    assert.equal(r.other, false);
    assert.equal(r.global, false);
  });

  test('a field may demand more than the baseline edit capability', async () => {
    const r = await lua.doString(`
      local A = NxcConfig.Access
      local editor = { 'config.resource.edit' }
      local draft = draftOf({
        { key = 'nxc_demo.startup.eager', scope = 'global', value = true },
      })
      local out = A.authoriseDraft(editor, draft)
      return { ok = out.ok, reason = out.error.details.fields[1].reason }
    `);
    // The field declares config.resource.publish, which is its author saying this
    // one is more dangerous than the rest.
    assert.equal(r.ok, false);
    assert.match(r.reason, /requires config\.resource\.publish/);
  });

  test('every denied field is reported, not just the first', async () => {
    const r = await lua.doString(`
      local A = NxcConfig.Access
      local draft = draftOf({
        { key = 'nxc_demo.startup.eager', scope = 'global', value = true },
        { key = 'nxc_demo.integration.webhook', scope = 'global', value = 'https://x.invalid' },
      })
      local out = A.authoriseDraft({}, draft)
      return { ok = out.ok, count = #out.error.details.fields }
    `);
    // Refused one field at a time is permissions learned one submission at a time.
    assert.equal(r.ok, false);
    assert.equal(r.count, 2);
  });

  test('editing and publishing are separate capabilities', async () => {
    const r = await lua.doString(`
      local A = NxcConfig.Access
      local draft = draftOf({
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
      })
      local editor = { 'config.resource.edit' }
      local publisher = { 'config.resource.edit', 'config.resource.publish' }
      return {
        editorMayEdit    = A.authoriseDraft(editor, draft).ok,
        editorMayPublish = A.authorisePublish(editor, draft).ok,
        publisherMay     = A.authorisePublish(publisher, draft).ok,
      }
    `);
    // Separating them is what allows a review step to exist at all.
    assert.equal(r.editorMayEdit, true);
    assert.equal(r.editorMayPublish, false);
    assert.equal(r.publisherMay, true);
  });

  test('rollback is its own capability', async () => {
    const r = await lua.doString(`
      local A = NxcConfig.Access
      return {
        withPublish  = A.authoriseRollback({ 'config.resource.publish' }, 'nxc_demo').ok,
        withRollback = A.authoriseRollback({ 'config.resource.rollback' }, 'nxc_demo').ok,
      }
    `);
    assert.equal(r.withPublish, false);
    assert.equal(r.withRollback, true);
  });

  test('a forbidden draft returns a structured error, not a bare false', async () => {
    const r = await lua.doString(`
      local draft = draftOf({ { key = 'nxc_demo.startup.eager', scope = 'global', value = true } })
      local out = NxcConfig.Access.authoriseDraft({}, draft)
      return { code = out.error.code, resource = out.error.resource }
    `);
    assert.equal(r.code, 'NXC_CONFIG_FORBIDDEN');
    assert.equal(r.resource, 'nxc_config');
  });
});

describe('Value visibility', () => {
  test('a sensitive value never leaves the server, for anyone', async () => {
    const r = await lua.doString(`
      local fields = NxcConfig.Registry.fields('nxc_demo')
      local values = {
        ['nxc_demo.limits.maxItems'] = 25,
        ['nxc_demo.startup.eager'] = true,
        ['nxc_demo.integration.webhook'] = 'https://secret.invalid/hook',
      }
      -- The most privileged actor there is.
      local visible, withheld = NxcConfig.Access.filterValues(fields, values, {
        audience = 'operator',
        resource = 'nxc_demo',
        held = { 'config.resource.view', 'config.resource.publish',
                 'config.resource.edit', 'config.resource.rollback' },
      })
      return {
        webhook = visible['nxc_demo.integration.webhook'],
        eager = visible['nxc_demo.startup.eager'],
        maxItems = visible['nxc_demo.limits.maxItems'],
        withheld = table.concat(withheld, ','),
      }
    `);
    // No capability unlocks a secret through this path. A management screen shows
    // that one is set, not what it is.
    assert.equal(r.webhook, undefined);
    assert.equal(r.withheld, 'nxc_demo.integration.webhook');
    // The privileged operator does see the non-client-visible one.
    assert.equal(r.eager, true);
    assert.equal(r.maxItems, 25);
  });

  test('a client sees only client-visible values', async () => {
    const r = await lua.doString(`
      local fields = NxcConfig.Registry.fields('nxc_demo')
      local values = {
        ['nxc_demo.limits.maxItems'] = 25,
        ['nxc_demo.startup.eager'] = true,
        ['nxc_demo.integration.webhook'] = 'https://secret.invalid/hook',
      }
      local visible, withheld = NxcConfig.Access.filterValues(fields, values,
        { audience = 'client' })
      local n = 0
      for _ in pairs(visible) do n = n + 1 end
      return { count = n, maxItems = visible['nxc_demo.limits.maxItems'],
               withheld = table.concat(withheld, ',') }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.maxItems, 25);
    assert.equal(r.withheld, 'nxc_demo.integration.webhook,nxc_demo.startup.eager');
  });

  test('an operator without view sees no more than a client', async () => {
    const r = await lua.doString(`
      local fields = NxcConfig.Registry.fields('nxc_demo')
      local values = { ['nxc_demo.startup.eager'] = true }
      local visible, withheld = NxcConfig.Access.filterValues(fields, values, {
        audience = 'operator', resource = 'nxc_demo', held = { 'config.resource.edit' },
      })
      -- Returned inside a table rather than bare: a lone nil out of doString does
      -- not arrive as undefined, and a test that cannot tell nil from absent is
      -- not testing the thing it names.
      return { eager = visible['nxc_demo.startup.eager'],
               withheld = table.concat(withheld, ',') }
    `);
    // Holding edit is not holding view. Being able to change a thing and being
    // able to read it are different grants.
    assert.equal(r.eager, undefined);
    // The sensitive webhook is withheld too, as it is from everyone.
    assert.equal(r.withheld, 'nxc_demo.integration.webhook,nxc_demo.startup.eager');
  });

  test('view scoped to another resource does not unlock this one', async () => {
    const r = await lua.doString(`
      local fields = NxcConfig.Registry.fields('nxc_demo')
      local values = { ['nxc_demo.startup.eager'] = true }
      local visible, withheld = NxcConfig.Access.filterValues(fields, values, {
        audience = 'operator', resource = 'nxc_demo',
        held = { 'config.resource.view:nxc_banking' },
      })
      return { eager = visible['nxc_demo.startup.eager'],
               withheld = table.concat(withheld, ',') }
    `);
    assert.equal(r.eager, undefined);
    // The sensitive webhook is withheld too, as it is from everyone.
    assert.equal(r.withheld, 'nxc_demo.integration.webhook,nxc_demo.startup.eager');
  });
});
