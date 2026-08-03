--- Schema registration.
---
--- A resource declares its configurable fields; this validates and stores them.
--- Nothing can be published to a key that was never registered, which is what
--- stops the value store filling with settings nobody reads.
---
--- **Registration is event-driven, not a startup dependency** (ADR-0013).
--- `nxc_config` starts fourth, and `nxc_ui` and `nxc_zones` start before it.
--- Treating registration as a startup dependency would create a real cycle, so
--- instead `nxc_config` announces readiness and resources register then. Until
--- they do, each runs on its declared defaults — which are part of the schema,
--- making that defined behaviour rather than a fallback.

local Registry = {}

--- Every property a field must declare. MDD 37.5.
Registry.REQUIRED_PROPERTIES = {
    'key', 'type', 'description', 'default', 'validation', 'scope', 'clientVisible',
    'editCapability', 'auditClassification', 'sensitive', 'reloadBehavior',
    'migrationBehavior', 'rollbackBehavior', 'changeEvent',
}

Registry.TYPES = {
    string = true, integer = true, number = true, boolean = true,
}

--- MDD 37.4. The two restart values are exceptions, and a field claiming one
--- should carry a technical reason in its description.
Registry.RELOAD_BEHAVIORS = {
    ['Immediate'] = true,
    ['Next Interaction'] = true,
    ['Next Session'] = true,
    ['Resource Restart Required'] = true,
    ['Server Restart Required'] = true,
}

Registry.AUDIT_CLASSIFICATIONS = {
    operational = true, security = true, financial = true, safety = true,
}

local schemas = {}   -- resource -> { fields = {}, byKey = {}, registeredAt = n }

--- Validate one field declaration.
---
---@param field table
---@param resource string
---@return string[] problems
function Registry.validateField(field, resource)
    local problems = {}
    local key = (type(field) == 'table' and field.key) or '(no key)'

    if type(field) ~= 'table' then
        return { 'field is not a table' }
    end

    for _, prop in ipairs(Registry.REQUIRED_PROPERTIES) do
        if field[prop] == nil then
            problems[#problems + 1] = ('%s: missing property %s'):format(key, prop)
        end
    end

    -- The key namespaces the field to its owner. Without this a resource could
    -- register a key belonging to another and quietly shadow it.
    if type(field.key) == 'string' then
        local owner = field.key:match('^([%w_]+)%.')
        if owner ~= resource then
            problems[#problems + 1] = ('%s: key must begin with %s.'):format(key, resource)
        end
        if not field.key:match('^[%w_]+%.[%a][%w]*%.[%a][%w]*$') then
            problems[#problems + 1] =
                ('%s: key must be <resource>.<group>.<name>'):format(key)
        end
    end

    if field.type and not Registry.TYPES[field.type] then
        problems[#problems + 1] = ('%s: unknown type %s'):format(key, tostring(field.type))
    end
    if field.reloadBehavior and not Registry.RELOAD_BEHAVIORS[field.reloadBehavior] then
        problems[#problems + 1] =
            ('%s: unknown reload behavior %s'):format(key, tostring(field.reloadBehavior))
    end
    if field.auditClassification
        and not Registry.AUDIT_CLASSIFICATIONS[field.auditClassification] then
        problems[#problems + 1] = ('%s: unknown audit classification %s')
            :format(key, tostring(field.auditClassification))
    end

    -- A sensitive value that is client-visible is a contradiction, and the
    -- resolution layer would honour clientVisible. Refused here instead.
    if field.sensitive == true and field.clientVisible == true then
        problems[#problems + 1] = ('%s: a sensitive field cannot be client-visible'):format(key)
    end

    if type(field.scope) ~= 'table' or #field.scope == 0 then
        problems[#problems + 1] = ('%s: must declare at least one scope'):format(key)
    else
        for _, scope in ipairs(field.scope) do
            if not NxcConfig.Scopes.isKnown(scope) or scope == 'default' then
                problems[#problems + 1] = ('%s: %s is not a settable scope'):format(key, tostring(scope))
            end
        end
    end

    -- The declared default must satisfy the declared validation, or a resource
    -- starts on a value its own management screen would reject.
    if field.default ~= nil and field.validation ~= nil and Registry.TYPES[field.type] then
        local ok, reason = Registry.checkValue(field, field.default)
        if not ok then
            problems[#problems + 1] = ('%s: the declared default is invalid: %s'):format(key, reason)
        end
    end

    return problems
end

--- Check a value against a field's declared type and validation.
---
--- The same function is used at registration, at draft time, and at publication,
--- so a value accepted in one place cannot be refused in another.
---
---@param field table
---@param value any
---@return boolean, string|nil
function Registry.checkValue(field, value)
    local expected, actual = field.type, type(value)

    if expected == 'integer' then
        if actual ~= 'number' or value ~= math.floor(value) then
            return false, 'must be a whole number'
        end
    elseif expected == 'number' then
        if actual ~= 'number' then return false, 'must be a number' end
    elseif actual ~= expected then
        return false, 'must be a ' .. tostring(expected)
    end

    local rules = field.validation or {}
    if rules.min and value < rules.min then
        return false, ('must be at least %s'):format(rules.min)
    end
    if rules.max and value > rules.max then
        return false, ('must be at most %s'):format(rules.max)
    end
    if rules.pattern and not tostring(value):match(rules.pattern) then
        return false, 'is not in the expected format'
    end
    if rules.oneOf then
        for _, allowed in ipairs(rules.oneOf) do
            if value == allowed then return true, nil end
        end
        return false, 'must be one of: ' .. table.concat(rules.oneOf, ', ')
    end
    return true, nil
end

--- Register a resource's schema.
---
--- **Re-registration replaces, and that is deliberate.** A resource restart
--- re-registers, and the new declaration is authoritative — it is the running
--- code. Merging would leave fields belonging to a version nobody is running.
---
--- Published values for keys that no longer exist are NOT deleted here. That is
--- a separate decision with a separate audit trail; silently discarding an
--- operator's settings because a developer renamed a key is not a thing a
--- configuration service should do quietly.
---
---@param resource string
---@param fields table[]
---@param nowMs integer|nil
---@return NxcResult
function Registry.register(resource, fields, nowMs)
    if type(resource) ~= 'string' or resource == '' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'resource', reason = 'is required' } } }))
    end
    if type(fields) ~= 'table' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { { field = 'fields', reason = 'must be a list' } } }))
    end

    local problems, byKey = {}, {}
    for _, field in ipairs(fields) do
        for _, problem in ipairs(Registry.validateField(field, resource)) do
            problems[#problems + 1] = { field = resource, reason = problem }
        end
        if type(field) == 'table' and type(field.key) == 'string' then
            if byKey[field.key] then
                problems[#problems + 1] =
                    { field = resource, reason = ('%s: duplicate key'):format(field.key) }
            end
            byKey[field.key] = field
        end
    end

    if #problems > 0 then
        -- Nothing is stored. A partial schema is worse than none: the resource
        -- would run believing it registered, and half its settings would be
        -- unmanageable with no error anywhere.
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = problems }))
    end

    local previous = schemas[resource]
    schemas[resource] = {
        fields = fields,
        byKey = byKey,
        registeredAt = nowMs or Nxc.Time.nowMs(),
    }

    local removed = {}
    if previous then
        for key in pairs(previous.byKey) do
            if not byKey[key] then removed[#removed + 1] = key end
        end
        table.sort(removed)
    end

    return Nxc.Result.ok({
        resource = resource,
        fieldCount = #fields,
        replaced = previous ~= nil,
        -- Reported so the caller can log it. A key disappearing between versions
        -- is a migration event, and it should be visible rather than inferred.
        removedKeys = removed,
    })
end

---@param resource string
---@return table[]|nil
function Registry.fields(resource)
    local schema = schemas[resource]
    return schema and schema.fields or nil
end

---@param key string
---@return table|nil field, string|nil resource
function Registry.field(key)
    for resource, schema in pairs(schemas) do
        local found = schema.byKey[key]
        if found then return found, resource end
    end
    return nil, nil
end

---@param resource string
---@return boolean
function Registry.isRegistered(resource)
    return schemas[resource] ~= nil
end

--- Every registered resource, sorted.
---
---@return string[]
function Registry.resources()
    local out = {}
    for resource in pairs(schemas) do out[#out + 1] = resource end
    table.sort(out)
    return out
end

--- Test helper.
function Registry.reset()
    schemas = {}
end

NxcConfig.Registry = Registry
return Registry
