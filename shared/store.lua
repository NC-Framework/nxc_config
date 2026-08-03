--- The value store interface, and an in-memory implementation.
---
--- `nxc_config` owns three tables (ADR-0013): schemas, values, and publications.
--- This defines what the service needs from them and ships a working in-memory
--- version, so every rule above it is testable without a database.
---
--- **Values are versioned by publication, never overwritten.** That is the single
--- structural decision that makes rollback a first-class operation rather than a
--- manual redo: restoring a prior state means selecting an earlier publication,
--- not re-editing values back to what someone remembers they were.
---
--- The consequence is that the value table grows monotonically and the "current"
--- value of a key at a scope is the newest record for it. Retention is an open
--- question (ADR-0013), and it is a real one — this table is append-only for the
--- life of the server.

local Store = {}

--- An in-memory store.
---
--- Not only a test double. It is also what `nxc_config` runs on before its
--- database is reachable, which is what lets resources register during startup
--- rather than waiting — registration is event-driven precisely so it does not
--- become a startup dependency.
---
---@return table
function Store.inMemory()
    local values = {}        -- ordered list of value records
    local publications = {}  -- ordered list
    local byIdempotency = {} -- key -> publication

    local self = {}

    --- Every value record, in publication order.
    ---
    --- Order is the contract: resolution treats a later record at the same scope
    --- as the newer publication, so a store that returned these unordered would
    --- resolve non-deterministically.
    ---
    ---@param filter table|nil  { key?, resource?, scope?, scopeId? }
    ---@return table[]
    function self.values(filter)
        filter = filter or {}
        local out = {}
        for _, record in ipairs(values) do
            local match = true
            if filter.key and record.key ~= filter.key then match = false end
            if filter.resource and record.resource ~= filter.resource then match = false end
            if filter.scope and record.scope ~= filter.scope then match = false end
            if filter.scopeId and record.scopeId ~= filter.scopeId then match = false end
            if match then out[#out + 1] = record end
        end
        return out
    end

    --- Append value records under one publication.
    ---
    ---@param records table[]
    function self.appendValues(records)
        for _, record in ipairs(records) do
            values[#values + 1] = record
        end
    end

    ---@param publication table
    function self.appendPublication(publication)
        publications[#publications + 1] = publication
        if publication.idempotencyKey then
            byIdempotency[publication.idempotencyKey] = publication
        end
    end

    ---@param idempotencyKey string
    ---@return table|nil
    function self.publicationByIdempotencyKey(idempotencyKey)
        return byIdempotency[idempotencyKey]
    end

    ---@param id string
    ---@return table|nil
    function self.publication(id)
        for _, p in ipairs(publications) do
            if p.id == id then return p end
        end
        return nil
    end

    --- Publications newest first, optionally for one resource.
    ---
    --- Newest first because every caller — a history screen, a rollback picker —
    --- wants the recent ones, and reversing at each call site is how one of them
    --- ends up not doing it.
    ---
    ---@param resource string|nil
    ---@param limit integer|nil
    ---@return table[]
    function self.publications(resource, limit)
        local out = {}
        for i = #publications, 1, -1 do
            local p = publications[i]
            if not resource or p.resource == resource then
                out[#out + 1] = p
                if limit and #out >= limit then break end
            end
        end
        return out
    end

    --- Test and diagnostic helper.
    function self.counts()
        return { values = #values, publications = #publications }
    end

    return self
end

NxcConfig.Store = Store
return Store
