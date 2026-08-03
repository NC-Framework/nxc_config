--- Configuration scopes and precedence resolution.
---
--- A value can be set at several levels at once. Resolution decides which one a
--- caller actually gets, and the order is fixed by MDD section 37.3:
---
---     default → environment → global → resource → organization → location → player
---
--- Lowest to highest. A player preference beats a location setting, which beats
--- an organization's, and so on down to the schema's declared default.
---
--- **Resolution is pure.** Values in, effective value out. No database, no
--- caching, no events — those belong to the caller, and keeping them out is what
--- makes the precedence rules testable at all.

local Scopes = {}

--- The ladder, lowest precedence first.
---
--- `default` is not a scope anyone writes to. It is the schema's declared value
--- and the floor of the ladder, which is why a resource can run correctly before
--- `nxc_config` has published anything to it.
Scopes.ORDER = {
    'default',
    'environment',
    'global',
    'resource',
    'organization',
    'location',
    'player',
}

--- Scopes that identify a subject and therefore need an id.
---
--- A value at `organization` scope without saying which organization is not a
--- value, it is a bug that resolves for everyone.
Scopes.REQUIRES_ID = {
    organization = true,
    location = true,
    player = true,
}

local RANK = {}
for index, name in ipairs(Scopes.ORDER) do RANK[name] = index end

--- Numeric precedence, higher wins.
---
---@param scope string
---@return integer|nil
function Scopes.rank(scope)
    return RANK[scope]
end

---@param scope string
---@return boolean
function Scopes.isKnown(scope)
    return RANK[scope] ~= nil
end

--- Whether a field may be set at a scope.
---
--- Two conditions, and both matter. The scope must exist, and the field must
--- declare it — a field scoped `{ 'global' }` set per player would resolve
--- differently for different people, which is exactly what its author said it
--- must not do.
---
---@param field table
---@param scope string
---@return boolean, string|nil
function Scopes.permits(field, scope)
    if not Scopes.isKnown(scope) then
        return false, ('unknown scope: %s'):format(tostring(scope))
    end
    if scope == 'default' then
        return false, 'the default comes from the schema and cannot be set'
    end
    for _, allowed in ipairs(field.scope or {}) do
        if allowed == scope then return true, nil end
    end
    return false, ('%s is not one of this field\'s scopes (%s)')
        :format(scope, table.concat(field.scope or {}, ', '))
end

--- Validate a value record before it is stored.
---
---@param field table
---@param record { scope: string, scopeId?: string }
---@return boolean, string|nil
function Scopes.validateRecord(field, record)
    local ok, reason = Scopes.permits(field, record.scope)
    if not ok then return false, reason end

    local needsId = Scopes.REQUIRES_ID[record.scope] == true
    local hasId = type(record.scopeId) == 'string' and record.scopeId ~= ''

    if needsId and not hasId then
        return false, ('%s scope requires a scopeId naming the subject'):format(record.scope)
    end
    if not needsId and hasId then
        -- Silently ignoring it would leave a value that looks targeted and is
        -- not, which resolves for everyone and reads in the audit log as though
        -- it did not.
        return false, ('%s scope takes no scopeId, but one was supplied'):format(record.scope)
    end
    return true, nil
end

--- Whether a stored record applies to a request.
---
--- A record at an identified scope applies only when the request names the same
--- subject. A request that does not mention an organization is not asking about
--- one, so organization-scoped values sit out of that resolution entirely.
---
---@param record { scope: string, scopeId?: string }
---@param context table  { environment?, resource?, organization?, location?, player? }
---@return boolean
function Scopes.applies(record, context)
    local scope = record.scope
    if not Scopes.isKnown(scope) or scope == 'default' then return false end

    if scope == 'global' then return true end

    local subject = context[scope]
    if subject == nil then return false end
    if Scopes.REQUIRES_ID[scope] then
        return tostring(subject) == tostring(record.scopeId)
    end
    -- environment and resource identify by matching the context value itself.
    return tostring(subject) == tostring(record.scopeId or subject)
end

--- Resolve the effective value for one field.
---
--- Returns the value, the scope that supplied it, and every scope that had a
--- value — the last of those is what an administration interface shows when it
--- explains *why* a setting is what it is, which is most of what makes a
--- configuration screen usable rather than mysterious.
---
---@param field table
---@param records { scope: string, scopeId?: string, value: any }[]
---@param context table
---@return { value: any, scope: string, scopeId: string|nil, overridden: table[] }
function Scopes.resolve(field, records, context)
    local winner = { value = field.default, scope = 'default', scopeId = nil }
    local considered = {}

    for _, record in ipairs(records or {}) do
        if Scopes.applies(record, context) and Scopes.permits(field, record.scope) then
            considered[#considered + 1] = record
            local rank = RANK[record.scope]
            if rank >= RANK[winner.scope] then
                -- `>=` rather than `>`: a later record at the same scope is a
                -- newer publication for that scope, and newer wins. Callers
                -- supply records in publication order.
                winner = { value = record.value, scope = record.scope, scopeId = record.scopeId }
            end
        end
    end

    -- Everything that had a value and lost, so an interface can say what it lost
    -- to rather than only what won.
    local overridden = {}
    for _, record in ipairs(considered) do
        if record.scope ~= winner.scope or record.scopeId ~= winner.scopeId then
            overridden[#overridden + 1] = {
                scope = record.scope, scopeId = record.scopeId, value = record.value,
            }
        end
    end

    return {
        value = winner.value,
        scope = winner.scope,
        scopeId = winner.scopeId,
        overridden = overridden,
    }
end

--- Resolve every field in a schema at once.
---
--- The common case: a resource asking for its whole configuration. Doing it
--- field by field would mean walking the record list once per field.
---
---@param fields table[]
---@param records table[]
---@param context table
---@return table<string, any> values, table<string, table> detail
function Scopes.resolveAll(fields, records, context)
    local byKey = {}
    for _, record in ipairs(records or {}) do
        byKey[record.key] = byKey[record.key] or {}
        local list = byKey[record.key]
        list[#list + 1] = record
    end

    local values, detail = {}, {}
    for _, field in ipairs(fields or {}) do
        local resolved = Scopes.resolve(field, byKey[field.key], context)
        values[field.key] = resolved.value
        detail[field.key] = resolved
    end
    return values, detail
end

--- Strip anything a client must not see.
---
--- **A sensitive value never leaves the server** (MDD 37.3), and a value that is
--- not client-visible is not sent either — those are two separate flags for two
--- separate reasons. Sensitive means disclosure is harmful; not client-visible
--- means the client has no business knowing, which is a smaller claim and still
--- sufficient.
---
---@param fields table[]
---@param values table<string, any>
---@return table<string, any>
function Scopes.clientView(fields, values)
    local out = {}
    for _, field in ipairs(fields or {}) do
        if field.clientVisible == true and field.sensitive ~= true then
            out[field.key] = values[field.key]
        end
    end
    return out
end

NxcConfig.Scopes = Scopes
return Scopes
