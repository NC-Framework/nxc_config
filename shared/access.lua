--- Who may do what to configuration.
---
--- Four capabilities (ADR-0013), scoped per resource so a business owner can
--- edit their own organization's settings without touching server-wide ones:
---
---     config.resource.edit       create and modify drafts
---     config.resource.publish    publish a validated draft
---     config.resource.rollback   restore a prior publication
---     config.resource.view       read effective values, including hidden ones
---
--- **Every check is server-side and every answer is a decision, not advice.**
--- A client asking what it may do gets an answer it cannot act on unilaterally,
--- because the same check runs again when it tries.
---
--- Pure: the caller supplies the actor's capabilities, this decides. Nothing
--- here reaches for a session, which is what makes the rules testable and what
--- keeps this module from having an opinion about where identity comes from.

local Access = {}

Access.EDIT     = 'config.resource.edit'
Access.PUBLISH  = 'config.resource.publish'
Access.ROLLBACK = 'config.resource.rollback'
Access.VIEW     = 'config.resource.view'

--- Whether a capability set contains one, allowing for scoping.
---
--- A capability may be held broadly (`config.resource.edit`) or narrowed to one
--- resource (`config.resource.edit:nxc_demo`). The narrow form grants nothing
--- anywhere else, which is the entire point of having it.
---
---@param held table<string, boolean>|string[]
---@param capability string
---@param resource string|nil
---@return boolean
function Access.holds(held, capability, resource)
    local set = held
    if #held > 0 then
        -- A list was supplied rather than a set. Accepted because callers
        -- naturally produce lists, and quietly returning false for one would be
        -- a permission bug that looks like a policy decision.
        set = {}
        for _, name in ipairs(held) do set[name] = true end
    end

    if set[capability] == true then return true end
    if resource and set[capability .. ':' .. resource] == true then return true end
    return false
end

--- Whether an actor may edit a specific field.
---
--- The field's own `editCapability` is the floor. A field declaring
--- `config.resource.publish` cannot be changed by someone holding only `edit` —
--- that declaration is the field author saying this one is more dangerous than
--- the rest.
---
---@param held table
---@param field table
---@param resource string
---@return boolean, string|nil
function Access.mayEditField(held, field, resource)
    local required = field.editCapability or Access.EDIT
    if Access.holds(held, required, resource) then return true, nil end
    return false, ('%s requires %s'):format(field.key, required)
end

--- Authorise a whole draft.
---
--- Every entry is checked and every failure is reported, rather than stopping at
--- the first. An operator who is refused one field at a time learns their
--- permissions one submission at a time.
---
---@param held table
---@param draft table
---@return NxcResult
function Access.authoriseDraft(held, draft)
    local denied = {}
    for _, entry in ipairs(draft.entries or {}) do
        local ok, reason = Access.mayEditField(held, entry.field, draft.resource)
        if not ok then
            denied[#denied + 1] = { field = entry.key, reason = reason }
        end
    end

    if #denied > 0 then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_FORBIDDEN',
            'You are not permitted to change some of these settings.',
            { resource = NxcConfig.RESOURCE, details = { fields = denied } }))
    end
    return Nxc.Result.ok(true)
end

--- Authorise publishing a draft.
---
--- Publishing is a separate capability from editing, deliberately. Drafting a
--- change and making it real are different acts, and separating them is what
--- allows a review step to exist at all.
---
---@param held table
---@param draft table
---@return NxcResult
function Access.authorisePublish(held, draft)
    local editable = Access.authoriseDraft(held, draft)
    if not editable.ok then return editable end

    if not Access.holds(held, Access.PUBLISH, draft.resource) then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_FORBIDDEN', 'You are not permitted to publish configuration changes.',
            { resource = NxcConfig.RESOURCE,
              details = { required = Access.PUBLISH, resource = draft.resource } }))
    end
    return Nxc.Result.ok(true)
end

---@param held table
---@param resource string
---@return NxcResult
function Access.authoriseRollback(held, resource)
    if not Access.holds(held, Access.ROLLBACK, resource) then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_FORBIDDEN', 'You are not permitted to roll back configuration.',
            { resource = NxcConfig.RESOURCE,
              details = { required = Access.ROLLBACK, resource = resource } }))
    end
    return Nxc.Result.ok(true)
end

--- Filter resolved values to what an actor may see.
---
--- Three separate rules, and they are not the same rule:
---
---   **sensitive** — disclosure is harmful. Never leaves the server, for anyone,
---   regardless of capability. There is no capability that reveals a secret
---   through this path, because a configuration screen is not the right place to
---   read one back.
---
---   **clientVisible = false** — the client has no business knowing. An operator
---   holding `view` may see it; a game client may not.
---
---   **everything else** — visible.
---
---@param fields table[]
---@param values table<string, any>
---@param opts { held?: table, resource?: string, audience: 'client'|'operator' }
---@return table<string, any> visible, string[] withheld
function Access.filterValues(fields, values, opts)
    opts = opts or { audience = 'client' }
    local visible, withheld = {}, {}

    local mayView = opts.audience == 'operator'
        and Access.holds(opts.held or {}, Access.VIEW, opts.resource)

    for _, field in ipairs(fields or {}) do
        if field.sensitive == true then
            -- No capability unlocks this here. A secret is written, not read
            -- back; a management screen shows that one is set, not what it is.
            withheld[#withheld + 1] = field.key
        elseif field.clientVisible == true or mayView then
            visible[field.key] = values[field.key]
        else
            withheld[#withheld + 1] = field.key
        end
    end

    table.sort(withheld)
    return visible, withheld
end

NxcConfig.Access = Access
return Access
