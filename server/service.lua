--- The registration handshake and the public server surface.
---
--- **Registration is event-driven, and that is a structural decision rather than
--- a stylistic one.** `nxc_config` starts fourth; `nxc_ui` and `nxc_zones` start
--- before it. If registering were a startup dependency, the dependency graph
--- would contain a real cycle. Instead this resource announces readiness and
--- resources register when they hear it, and each runs on its declared defaults
--- until then — which is defined behaviour, because defaults are part of the
--- schema.
---
--- Two events, and the difference matters:
---
---     nxc_config:server:ready       we are open; register now
---     nxc_config:server:register    a resource registering
---
--- A resource that starts LATER than nxc_config never hears `ready`, so it may
--- register unprompted at any time. Both paths land in the same handler.

if not IsDuplicityVersion() then return end

local Service = {}

local store = nil
local ready = false

---@return boolean
function Service.isReady() return ready end

---@return table|nil
function Service.store() return store end

--- Install the store and open for registration.
---
---@param installed table
function Service.open(installed)
    store = installed
    ready = true

    -- Announced after the store exists, never before. A resource that registered
    -- into a service with nowhere to put the schema would be told it succeeded.
    TriggerEvent('nxc_config:server:ready', {
        resource = NxcConfig.RESOURCE,
        version = NxcConfig.VERSION,
        contractVersion = NxcConfig.CONTRACT_VERSION,
    })

    Nxc.Logger.info('config.open', {
        contractVersion = NxcConfig.CONTRACT_VERSION,
    })
end

--- Handle a resource registering its schema.
---
--- Returns a Result so the caller learns whether it worked. A registration that
--- fails silently leaves a resource believing its settings are manageable when
--- they are not.
---
---@param resource string
---@param fields table[]
---@return NxcResult
function Service.register(resource, fields)
    if not ready then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_NOT_READY', 'The configuration service is not accepting registrations yet.',
            { resource = NxcConfig.RESOURCE, retryable = true }))
    end

    local registered = NxcConfig.Registry.register(resource, fields)
    if not registered.ok then
        -- Logged at error, not warn. A resource whose schema was refused has no
        -- manageable configuration at all, and the reasons are the only way
        -- anyone will know why.
        local reasons = {}
        for _, problem in ipairs(registered.error.details.fields or {}) do
            reasons[#reasons + 1] = problem.reason
        end
        Nxc.Logger.error('config.registration_refused', {
            registeringResource = resource,
            problems = reasons,
        })
        return registered
    end

    -- Best effort. A schema that cannot be cached to the database is still
    -- registered in memory and still fully usable; only the ability to inspect a
    -- stopped resource's settings is lost, and losing that must not fail a
    -- startup.
    local saved, saveErr = pcall(function() store.saveSchema(resource, fields) end)
    if not saved then
        Nxc.Logger.warn('config.schema_not_persisted', {
            registeringResource = resource,
            detail = tostring(saveErr),
        })
    end

    Nxc.Logger.info('config.registered', {
        registeringResource = resource,
        fields = registered.value.fieldCount,
        replaced = registered.value.replaced,
        removedKeys = registered.value.removedKeys,
    })

    return Nxc.Result.ok({
        resource = resource,
        fieldCount = registered.value.fieldCount,
        --- The registering resource's effective values, so it does not have to
        --- ask separately. This is the handshake completing: register, and
        --- receive what is in force.
        values = Service.effectiveValues(resource, {}),
    })
end

--- Effective values for a resource, with precedence applied.
---
---@param resource string
---@param context table|nil
---@return table<string, any>
function Service.effectiveValues(resource, context)
    local fields = NxcConfig.Registry.fields(resource)
    if not fields then return {} end
    if not store then
        -- Before the store exists, the schema defaults are the answer, and they
        -- are the correct answer rather than a placeholder.
        local values = {}
        for _, field in ipairs(fields) do values[field.key] = field.default end
        return values
    end
    local values = NxcConfig.Scopes.resolveAll(fields, store.values({ resource = resource }),
        context or {})
    return values
end

AddEventHandler('nxc_config:server:register', function(resource, fields)
    -- The registering resource is taken from the EVENT SOURCE where possible,
    -- not from the payload. A resource naming itself is making a claim.
    local claimed = resource
    local actual = GetInvokingResource()
    if actual and actual ~= claimed then
        Nxc.Logger.error('config.registration_identity_mismatch', {
            claimed = claimed,
            actual = actual,
            detail = 'a resource may only register its own schema',
        })
        return
    end
    Service.register(actual or claimed, fields)
end)

--- Exports, because a consumer in another resource cannot call into this Lua
--- state directly. This is the case exports are actually for: a service with one
--- owner, called by many, at a rate measured in restarts rather than frames.
--- EVERY EXPORT RETURNS A PLAIN TABLE.
---
--- A Result is frozen, and a frozen table is raw-empty — its contents live
--- behind a metatable that FiveM's marshalling does not follow. Returning one
--- directly sends `{}`, so the caller sees no `ok` field and reports failure
--- while this side logs success. That is precisely what happened on a real
--- server before `Nxc.plain` existed.
exports('register', function(fields)
    local resource = GetInvokingResource()
    if not resource then
        return { ok = false, error = { code = 'NXC_CONFIG_UNKNOWN_CALLER' } }
    end
    return Nxc.plain(Service.register(resource, fields))
end)

exports('effectiveValues', function(context)
    local resource = GetInvokingResource()
    if not resource then return {} end
    return Nxc.plain(Service.effectiveValues(resource, context))
end)

exports('isReady', function() return ready end)

--- Publish a validated, authorised draft and announce it.
---
--- The one place a publication becomes real on a running server.
---
---@param opts table
---@return NxcResult
function Service.publish(opts)
    if not ready then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_NOT_READY', 'The configuration service is not ready.',
            { resource = NxcConfig.RESOURCE, retryable = true }))
    end

    local published = NxcConfig.Publication.publish({
        draft = opts.draft,
        store = store,
        actor = opts.actor,
        capability = opts.capability,
        correlationId = opts.correlationId,
        idempotencyKey = opts.idempotencyKey,
        rollbackOf = opts.rollbackOf,
    })
    if not published.ok then return published end

    -- A replay must not announce a second time. Subscribers re-resolve on the
    -- event, and re-resolving to the same values is harmless but the log line
    -- claiming a second publication is not.
    if not published.value.replayed then
        TriggerEvent('nxc_config:server:changed', published.value.event)
        Nxc.Logger.info('config.published', {
            publicationId = published.value.publication.id,
            forResource = published.value.publication.resource,
            actor = published.value.publication.actor,
            keys = published.value.event.keys,
            correlationId = opts.correlationId,
        })
    end

    return published
end

NxcConfig.Service = Service
return Service
