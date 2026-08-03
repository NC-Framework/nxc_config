--- Publication: the moment a draft becomes real, and how it is undone.
---
--- One function, called once, producing one audit record. MDD 37.7 and ADR-0013.
---
--- Three properties, each for a stated reason:
---
---   **Atomic.** All fields in a publication apply, or none. A half-applied
---   publication leaves a server in a state nobody designed and nobody can name.
---
---   **Idempotent.** A retried publication with the same key does not publish
---   twice (directive 16.4). Retries happen — a request times out and the
---   operator clicks again — and a configuration change applied twice is at best
---   a confusing audit trail and at worst two rollback steps where there should
---   be one.
---
---   **Audited.** Actor, capability, before, after, correlation id.
---
--- **The change event carries keys, not values.** An event carrying values would
--- replicate sensitive configuration to every subscriber, so consumers are told
--- what changed and re-resolve it themselves through a path that applies the
--- sensitivity rules.

local Publication = {}

--- Publish a validated draft.
---
---@param opts { draft: table, store: table, actor?: string, capability?: string, correlationId?: string, idempotencyKey?: string, nowMs?: integer }
---@return NxcResult
function Publication.publish(opts)
    if type(opts) ~= 'table' or type(opts.draft) ~= 'table' or type(opts.store) ~= 'table' then
        error('Publication.publish requires a draft and a store', 2)
    end

    local draft, store = opts.draft, opts.store

    -- Idempotency is checked FIRST, before anything is written. Checking
    -- afterwards would mean the second publication had already happened.
    if opts.idempotencyKey then
        local existing = store.publicationByIdempotencyKey(opts.idempotencyKey)
        if existing then
            return Nxc.Result.ok({
                publication = existing,
                --- The caller needs to distinguish "published" from "already
                --- published", because one of them should not emit a change
                --- event a second time.
                replayed = true,
            })
        end
    end

    local preview = NxcConfig.Drafts.preview(draft, store)
    if not preview.ok then return preview end

    if preview.value.isNoOp then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_NOTHING_TO_PUBLISH',
            'Every value in this draft is already in force.',
            { resource = NxcConfig.RESOURCE,
              details = { unchanged = #preview.value.unchanged } }))
    end

    local nowMs = opts.nowMs or Nxc.Time.nowMs()
    local id = Nxc.Correlation.new():gsub('^c%-', 'pub_')

    local records, changes, changedKeys = {}, {}, {}
    for _, change in ipairs(preview.value.changes) do
        records[#records + 1] = {
            key = change.key,
            resource = draft.resource,
            scope = change.scope,
            scopeId = change.scopeId,
            value = change.to,
            publicationId = id,
            appliedAt = nowMs,
        }
        changes[#changes + 1] = {
            key = change.key,
            scope = change.scope,
            scopeId = change.scopeId,
            -- Before and after are kept in the AUDIT record, which is
            -- server-side and access-controlled. They are not in the event.
            from = change.from,
            to = change.to,
            reloadBehavior = change.reloadBehavior,
            auditClassification = change.auditClassification,
            sensitive = change.sensitive,
        }
        changedKeys[#changedKeys + 1] = change.key
    end

    local publication = {
        id = id,
        resource = draft.resource,
        actor = opts.actor or draft.actor,
        capability = opts.capability,
        correlationId = opts.correlationId,
        idempotencyKey = opts.idempotencyKey,
        publishedAt = nowMs,
        changes = changes,
        rollbackOf = opts.rollbackOf,
    }

    -- Values first, then the publication record. If the second write failed, a
    -- reader would see values with no publication — visibly wrong. The reverse
    -- would be a publication claiming changes that never landed, which reads as
    -- correct and is not.
    store.appendValues(records)
    store.appendPublication(publication)

    return Nxc.Result.ok({
        publication = publication,
        replayed = false,
        --- What goes on the wire. Keys and reload behaviour only: a subscriber
        --- learns what to re-resolve, never what the value is.
        event = Publication.changeEvent(publication),
    })
end

--- The change event for a publication.
---
--- Deliberately thin. Consumers re-resolve, which keeps sensitive values off the
--- wire and means a subscriber cannot act on a value it was not entitled to see.
---
---@param publication table
---@return table
function Publication.changeEvent(publication)
    local keys, behaviors = {}, {}
    for _, change in ipairs(publication.changes) do
        keys[#keys + 1] = change.key
        -- Carried because a subscriber needs to know whether to apply the change
        -- now, at the next interaction, at the next session, or not at all
        -- without a restart. That is metadata about the field, not the value.
        behaviors[change.key] = change.reloadBehavior
    end
    return {
        publicationId = publication.id,
        resource = publication.resource,
        keys = keys,
        reloadBehavior = behaviors,
        publishedAt = publication.publishedAt,
    }
end

--- Build the draft that would restore a prior publication.
---
--- **Rollback is a forward operation.** It publishes a new publication whose
--- values are the ones in force before the target — it does not delete history.
--- An audit trail with holes in it is not an audit trail, and "what did we roll
--- back from" is exactly the question asked afterwards.
---
--- Fields declaring `rollbackBehavior = 'retain'` are skipped: some values must
--- not travel backwards, and a rollback that silently reverted one would be
--- worse than one that says it did not.
---
---@param publicationId string
---@param store table
---@return NxcResult
function Publication.planRollback(publicationId, store)
    local target = store.publication(publicationId)
    if not target then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_PUBLICATION_NOT_FOUND', 'That publication does not exist.',
            { resource = NxcConfig.RESOURCE, details = { publicationId = publicationId } }))
    end

    local entries, skipped = {}, {}
    for _, change in ipairs(target.changes) do
        local field = NxcConfig.Registry.field(change.key)
        if not field then
            -- The key has been deregistered since. Restoring a value nothing
            -- reads would be writing rubbish into the store.
            skipped[#skipped + 1] = { key = change.key, reason = 'no longer registered' }
        elseif field.rollbackBehavior == 'retain' then
            skipped[#skipped + 1] = { key = change.key, reason = 'declares rollbackBehavior retain' }
        elseif change.from == nil then
            -- There was no value before, so restoring means removing. Recorded
            -- as unsupported rather than approximated with the schema default,
            -- which is a different thing and would look identical afterwards.
            skipped[#skipped + 1] = { key = change.key,
                reason = 'had no prior value at this scope; removal is not yet supported' }
        else
            entries[#entries + 1] = {
                key = change.key,
                scope = change.scope,
                scopeId = change.scopeId,
                value = change.from,
            }
        end
    end

    if #entries == 0 then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_NOTHING_TO_ROLL_BACK',
            'Nothing in that publication can be rolled back.',
            { resource = NxcConfig.RESOURCE, details = { skipped = skipped } }))
    end

    return Nxc.Result.ok({
        resource = target.resource,
        entries = entries,
        skipped = skipped,
        rollbackOf = target.id,
    })
end

--- Every value record in force, for resolution.
---
---@param store table
---@param filter table|nil
---@return table[]
function Publication.effectiveRecords(store, filter)
    return store.values(filter)
end

NxcConfig.Publication = Publication
return Publication
