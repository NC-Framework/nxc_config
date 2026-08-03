--- Drafts: a proposed change, validated and previewed before it is real.
---
--- MDD 37.7's workflow is Draft → Validate → Preview impact → Publish. This is
--- the first three. Publication is separate on purpose: the moment a change
--- becomes real should be one function, called once, with an audit record.
---
--- **The preview is the point.** An operator changing a setting needs to know
--- what it currently is, what it will become, who it affects, and — the part
--- most configuration systems omit — whether the change takes effect at all
--- without a restart. Publishing and then discovering that is how a server ends
--- up restarted during peak hours.

local Drafts = {}

--- Build and validate a draft.
---
--- Every entry is checked independently and all problems are returned together,
--- because an operator fixing one at a time is an operator submitting five times.
---
---@param opts { resource: string, actor?: string, entries: { key: string, scope: string, scopeId?: string, value: any }[] }
---@return NxcResult
function Drafts.create(opts)
    if type(opts) ~= 'table' or type(opts.resource) ~= 'string' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'resource', reason = 'is required' } } }))
    end
    if type(opts.entries) ~= 'table' or #opts.entries == 0 then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'entries', reason = 'a draft must change something' } } }))
    end

    local problems, seen, entries = {}, {}, {}

    for index, entry in ipairs(opts.entries) do
        local label = tostring(entry.key or ('entry ' .. index))

        local field, owner = NxcConfig.Registry.field(entry.key)
        if not field then
            -- Refused rather than stored for later. A value for an unregistered
            -- key is unreachable — nothing resolves it, nothing validates it —
            -- and it would sit in the store looking like configuration.
            problems[#problems + 1] = { field = label, reason = 'is not a registered setting' }
        elseif owner ~= opts.resource then
            problems[#problems + 1] = { field = label,
                reason = ('belongs to %s, not %s'):format(owner, opts.resource) }
        else
            local scopeOk, scopeReason = NxcConfig.Scopes.validateRecord(field, entry)
            if not scopeOk then
                problems[#problems + 1] = { field = label, reason = scopeReason }
            end

            local valueOk, valueReason = NxcConfig.Registry.checkValue(field, entry.value)
            if not valueOk then
                problems[#problems + 1] = { field = label, reason = valueReason }
            end

            local identity = ('%s|%s|%s'):format(entry.key, entry.scope, entry.scopeId or '')
            if seen[identity] then
                -- Two values for one key at one scope in one draft: whichever
                -- wins does so by list order, which is not a decision anyone made.
                problems[#problems + 1] = { field = label,
                    reason = 'set twice at the same scope in one draft' }
            end
            seen[identity] = true

            if scopeOk and valueOk then
                entries[#entries + 1] = {
                    key = entry.key,
                    scope = entry.scope,
                    scopeId = entry.scopeId,
                    value = entry.value,
                    field = field,
                }
            end
        end
    end

    if #problems > 0 then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = problems }))
    end

    return Nxc.Result.ok({
        resource = opts.resource,
        actor = opts.actor,
        entries = entries,
        createdAt = opts.nowMs or Nxc.Time.nowMs(),
    })
end

--- What publishing this draft would do.
---
--- Compares each entry against the value currently in force at the same scope,
--- and reports the reload behaviour so nobody discovers it afterwards.
---
---@param draft table
---@param store table
---@return NxcResult
function Drafts.preview(draft, store)
    if type(draft) ~= 'table' or type(draft.entries) ~= 'table' then
        error('Drafts.preview requires a draft', 2)
    end

    local changes, unchanged = {}, {}
    local restartRequired, immediate = {}, {}

    for _, entry in ipairs(draft.entries) do
        local existing = store.values({
            key = entry.key, scope = entry.scope, scopeId = entry.scopeId,
        })
        local current = existing[#existing]   -- newest wins
        local from = current and current.value or nil
        local fromScope = current and 'set at this scope' or 'not set at this scope'

        local change = {
            key = entry.key,
            scope = entry.scope,
            scopeId = entry.scopeId,
            from = from,
            to = entry.value,
            fromState = fromScope,
            reloadBehavior = entry.field.reloadBehavior,
            auditClassification = entry.field.auditClassification,
            sensitive = entry.field.sensitive == true,
        }

        if from ~= nil and from == entry.value then
            -- Publishing a value identical to the one in force writes an audit
            -- record saying nothing happened. Reported so the operator can drop
            -- it, not silently discarded — they may have meant to reassert it.
            unchanged[#unchanged + 1] = change
        else
            changes[#changes + 1] = change
        end

        if entry.field.reloadBehavior == 'Resource Restart Required'
            or entry.field.reloadBehavior == 'Server Restart Required' then
            restartRequired[#restartRequired + 1] = entry.key
        elseif entry.field.reloadBehavior == 'Immediate' then
            immediate[#immediate + 1] = entry.key
        end
    end

    return Nxc.Result.ok({
        resource = draft.resource,
        changes = changes,
        unchanged = unchanged,
        --- The question an operator most needs answered before publishing, and
        --- the one most configuration systems answer afterwards.
        requiresRestart = #restartRequired > 0,
        restartKeys = restartRequired,
        immediateKeys = immediate,
        --- A draft consisting entirely of no-ops. Worth saying out loud rather
        --- than letting someone publish nothing and wonder why nothing changed.
        isNoOp = #changes == 0,
    })
end

NxcConfig.Drafts = Drafts
return Drafts
