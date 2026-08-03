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
      key = 'nxc_demo.limits.maxItems', type = 'integer',
      description = 'How many items may be held.', default = 10,
      validation = { min = 0, max = 1000 },
      scope = { 'global', 'organization' },
      clientVisible = true, editCapability = 'config.resource.edit',
      auditClassification = 'operational', sensitive = false,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'nxc_demo:server:limitsChanged',
    },
    {
      key = 'nxc_demo.startup.eager', type = 'boolean',
      description = 'Whether to do the thing at startup.', default = false,
      validation = {}, scope = { 'global' },
      clientVisible = false, editCapability = 'config.resource.publish',
      auditClassification = 'operational', sensitive = false,
      reloadBehavior = 'Resource Restart Required', migrationBehavior = 'retain',
      rollbackBehavior = 'restore', changeEvent = 'nxc_demo:server:startupChanged',
    },
    {
      key = 'nxc_demo.audit.retentionDays', type = 'integer',
      description = 'Never travels backwards.', default = 30,
      validation = { min = 1, max = 3650 }, scope = { 'global' },
      clientVisible = false, editCapability = 'config.resource.publish',
      auditClassification = 'security', sensitive = false,
      reloadBehavior = 'Immediate', migrationBehavior = 'retain',
      rollbackBehavior = 'retain', changeEvent = 'nxc_demo:server:auditChanged',
    },
  })
  store = NxcConfig.Store.inMemory()

  function draftOf(entries)
    return NxcConfig.Drafts.create({
      resource = 'nxc_demo', actor = 'acc_admin', entries = entries,
    }).value
  end

  function publish(entries, extra)
    local o = { draft = draftOf(entries), store = store, actor = 'acc_admin',
                capability = 'config.resource.publish' }
    for k, v in pairs(extra or {}) do o[k] = v end
    return NxcConfig.Publication.publish(o)
  end
`;

describe('Publishing', () => {
  test('a publication writes values and a record', async () => {
    const r = await lua.doString(`
      local out = publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      local counts = store.counts()
      return {
        ok = out.ok, replayed = out.value.replayed,
        values = counts.values, publications = counts.publications,
        id = out.value.publication.id,
        actor = out.value.publication.actor,
      }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.replayed, false);
    assert.equal(r.values, 1);
    assert.equal(r.publications, 1);
    assert.match(r.id, /^pub_/);
    assert.equal(r.actor, 'acc_admin');
  });

  test('a published value then resolves', async () => {
    const r = await lua.doString(`
      publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      local field = NxcConfig.Registry.field('nxc_demo.limits.maxItems')
      local resolved = NxcConfig.Scopes.resolve(field, store.values({ key = field.key }), {})
      return { value = resolved.value, scope = resolved.scope }
    `);
    // The end-to-end point of the whole resource: publish, then resolve.
    assert.equal(r.value, 25);
    assert.equal(r.scope, 'global');
  });

  test('a retry with the same idempotency key does not publish twice', async () => {
    const r = await lua.doString(`
      local first = publish(
        { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } },
        { idempotencyKey = 'req-1' })
      local second = publish(
        { { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } },
        { idempotencyKey = 'req-1' })
      local counts = store.counts()
      return {
        sameId = first.value.publication.id == second.value.publication.id,
        firstReplayed = first.value.replayed,
        secondReplayed = second.value.replayed,
        publications = counts.publications, values = counts.values,
      }
    `);
    // A request times out, the operator clicks again. Applied twice, that is at
    // best a confusing audit trail and at worst two rollback steps where there
    // should be one.
    assert.equal(r.sameId, true);
    assert.equal(r.firstReplayed, false);
    assert.equal(r.secondReplayed, true, 'the caller must be able to skip re-emitting the event');
    assert.equal(r.publications, 1);
    assert.equal(r.values, 1);
  });

  test('publishing nothing is refused', async () => {
    const r = await lua.doString(`
      publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      local out = publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CONFIG_NOTHING_TO_PUBLISH');
  });

  test('the change event carries keys and reload behaviour, never values', async () => {
    const r = await lua.doString(`
      local out = publish({
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
        { key = 'nxc_demo.startup.eager', scope = 'global', value = true },
      })
      local event = out.value.event

      -- Walk the whole event looking for the published values. Stronger than a
      -- string search: it proves nothing is reachable at any depth.
      local found = {}
      local function walk(node)
        if type(node) == 'table' then
          for k, v in pairs(node) do walk(k); walk(v) end
        else
          found[tostring(node)] = true
        end
      end
      walk(event)

      return {
        keys = table.concat(event.keys, ','),
        behaviorOfEager = event.reloadBehavior['nxc_demo.startup.eager'],
        carries25 = found['25'] == true,
        carriesTrue = found['true'] == true,
      }
    `);
    // An event carrying values would replicate sensitive configuration to every
    // subscriber. Consumers re-resolve through a path that applies the
    // sensitivity rules.
    assert.equal(r.keys, 'nxc_demo.limits.maxItems,nxc_demo.startup.eager');
    assert.equal(r.behaviorOfEager, 'Resource Restart Required');
    assert.equal(r.carries25, false, 'the event must not carry the value');
    assert.equal(r.carriesTrue, false);
  });

  test('the audit record keeps before and after, which the event does not', async () => {
    const r = await lua.doString(`
      publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      local out = publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 40 } })
      local change = out.value.publication.changes[1]
      return { from = change.from, to = change.to, capability = out.value.publication.capability }
    `);
    // Server-side and access-controlled, which is the difference from the event.
    assert.equal(r.from, 25);
    assert.equal(r.to, 40);
    assert.equal(r.capability, 'config.resource.publish');
  });

  test('a publication of several fields is one record, not several', async () => {
    const r = await lua.doString(`
      local out = publish({
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
        { key = 'nxc_demo.startup.eager', scope = 'global', value = true },
      })
      return { publications = store.counts().publications,
               values = store.counts().values,
               changes = #out.value.publication.changes }
    `);
    // Atomic: all of them apply under one id, so rollback is one step.
    assert.equal(r.publications, 1);
    assert.equal(r.values, 2);
    assert.equal(r.changes, 2);
  });
});

describe('Rollback', () => {
  test('rolling back restores the prior value as a NEW publication', async () => {
    const r = await lua.doString(`
      publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      local second = publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 40 } })

      local plan = NxcConfig.Publication.planRollback(second.value.publication.id, store).value
      local out = NxcConfig.Publication.publish({
        draft = NxcConfig.Drafts.create({ resource = plan.resource, entries = plan.entries }).value,
        store = store, actor = 'acc_admin', rollbackOf = plan.rollbackOf,
      })

      local field = NxcConfig.Registry.field('nxc_demo.limits.maxItems')
      local resolved = NxcConfig.Scopes.resolve(field, store.values({ key = field.key }), {})
      return {
        value = resolved.value,
        publications = store.counts().publications,
        rollbackOf = out.value.publication.rollbackOf,
      }
    `);
    // Forward, not destructive: history keeps all three, and "what did we roll
    // back from" is answerable.
    assert.equal(r.value, 25);
    assert.equal(r.publications, 3);
    assert.ok(r.rollbackOf);
  });

  test('a field declaring rollbackBehavior retain is skipped, and says so', async () => {
    const r = await lua.doString(`
      -- Both keys need a prior value, or they are skipped for having none and
      -- the distinction this test is about never comes up.
      publish({
        { key = 'nxc_demo.audit.retentionDays', scope = 'global', value = 60 },
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 10 },
      })
      local target = publish({
        { key = 'nxc_demo.audit.retentionDays', scope = 'global', value = 90 },
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
      })
      local plan = NxcConfig.Publication.planRollback(target.value.publication.id, store).value
      return {
        entries = #plan.entries,
        entryKey = plan.entries[1].key,
        skippedKey = plan.skipped[1].key,
        skippedReason = plan.skipped[1].reason,
      }
    `);
    // Some values must not travel backwards. A rollback that silently reverted
    // one would be worse than one that says it did not.
    assert.equal(r.entries, 1);
    assert.equal(r.entryKey, 'nxc_demo.limits.maxItems');
    assert.equal(r.skippedKey, 'nxc_demo.audit.retentionDays');
    assert.match(r.skippedReason, /rollbackBehavior retain/);
  });

  test('a first-ever value cannot be rolled back, and is not faked with the default', async () => {
    const r = await lua.doString(`
      local first = publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 } })
      local out = NxcConfig.Publication.planRollback(first.value.publication.id, store)
      return { ok = out.ok, code = out.error.code,
               reason = out.error.details.skipped[1].reason }
    `);
    // Restoring "no value" is removal, which is a different operation. Using the
    // schema default instead would look identical afterwards and be wrong.
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CONFIG_NOTHING_TO_ROLL_BACK');
    assert.match(r.reason, /no prior value/);
  });

  test('rolling back an unknown publication fails by name', async () => {
    const r = await lua.doString(`
      local out = NxcConfig.Publication.planRollback('pub_nonexistent', store)
      return { ok = out.ok, code = out.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_CONFIG_PUBLICATION_NOT_FOUND');
  });

  test('a key deregistered since publication is skipped rather than restored', async () => {
    const r = await lua.doString(`
      local target = publish({
        { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 25 },
      })
      publish({ { key = 'nxc_demo.limits.maxItems', scope = 'global', value = 40 } })

      -- The resource re-registers without that field.
      NxcConfig.Registry.register('nxc_demo', {
        {
          key = 'nxc_demo.startup.eager', type = 'boolean', description = 'd',
          default = false, validation = {}, scope = { 'global' },
          clientVisible = false, editCapability = 'config.resource.publish',
          auditClassification = 'operational', sensitive = false,
          reloadBehavior = 'Immediate', migrationBehavior = 'retain',
          rollbackBehavior = 'restore', changeEvent = 'e',
        },
      })

      local out = NxcConfig.Publication.planRollback(target.value.publication.id, store)
      return { ok = out.ok, reason = out.error.details.skipped[1].reason }
    `);
    // Restoring a value nothing reads would be writing rubbish into the store.
    assert.equal(r.ok, false);
    assert.match(r.reason, /no longer registered/);
  });
});
