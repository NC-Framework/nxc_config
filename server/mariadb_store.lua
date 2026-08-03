--- The MariaDB-backed value store.
---
--- Implements the same interface as `Store.inMemory`, so everything above it is
--- already tested. This file is the part that cannot be: it speaks to oxmysql.
---
--- **Kept as thin as the interface allows**, for the same reason nxc_core's
--- provider is. It cannot be unit tested, so anything with a decision in it
--- belongs above this line where it can be.
---
--- One thing here is more than translation and is called out where it happens:
--- values are stored as JSON so they keep their type. A boolean stored as '1'
--- returns as a string and compares unequal to the boolean it was, which
--- surfaces as a setting that will not turn off.

if not IsDuplicityVersion() then return end

local MariaDBStore = {}

local RESOURCE = NxcConfig.RESOURCE

--- Wrap a scoped persistence provider in the store interface.
---
---@param db table  a provider scoped to nxc_config
---@return table
function MariaDBStore.create(db)
    local self = {}

    local function unwrap(result, what)
        if type(result) ~= 'table' or result.ok == nil then
            error(('%s: provider did not return a Result'):format(what), 0)
        end
        if not result.ok then
            local err = result.error or {}
            error(('%s: %s'):format(what,
                tostring((err.details and err.details.reason) or err.message or err.code)), 0)
        end
        return result.value or {}
    end

    --- Decode a stored value, preserving its type.
    ---
    --- json.decode returns nil for the literal `null` and for malformed input
    --- alike, so the two are distinguished before decoding rather than after.
    local function decode(raw)
        if raw == nil then return nil end
        if type(raw) ~= 'string' then return raw end
        local ok, decoded = pcall(json.decode, raw)
        if not ok then return nil end
        return decoded
    end

    function self.values(filter)
        filter = filter or {}
        local sql = 'SELECT config_key, resource, scope, scope_id, value, publication_id '
                 .. 'FROM nxc_config_values WHERE 1 = 1'
        local params = {}
        if filter.key then
            sql = sql .. ' AND config_key = ?'; params[#params + 1] = filter.key
        end
        if filter.resource then
            sql = sql .. ' AND resource = ?'; params[#params + 1] = filter.resource
        end
        if filter.scope then
            sql = sql .. ' AND scope = ?'; params[#params + 1] = filter.scope
        end
        if filter.scopeId then
            sql = sql .. ' AND scope_id = ?'; params[#params + 1] = filter.scopeId
        end
        -- Publication order. Resolution treats a later row at the same scope as
        -- the newer publication, so an unordered read resolves
        -- non-deterministically.
        sql = sql .. ' ORDER BY id'

        local rows = unwrap(db.query(sql, params), 'reading configuration values')
        local out = {}
        for _, row in ipairs(rows) do
            out[#out + 1] = {
                key = row.config_key,
                resource = row.resource,
                scope = row.scope,
                scopeId = row.scope_id,
                value = decode(row.value),
                publicationId = row.publication_id,
            }
        end
        return out
    end

    function self.appendValues(records)
        if #records == 0 then return end
        local statements = {}
        for _, record in ipairs(records) do
            statements[#statements + 1] = {
                query = 'INSERT INTO nxc_config_values '
                     .. '(publication_id, resource, config_key, scope, scope_id, value) '
                     .. 'VALUES (?, ?, ?, ?, ?, ?)',
                values = {
                    record.publicationId, record.resource, record.key,
                    record.scope, record.scopeId,
                    -- Encoded so the type survives the round trip.
                    json.encode(record.value),
                },
            }
        end
        unwrap(db.transaction(statements), 'writing configuration values')
    end

    function self.appendPublication(publication)
        unwrap(db.execute(
            'INSERT INTO nxc_config_publications '
         .. '(id, resource, actor, capability, correlation_id, idempotency_key, '
         .. ' rollback_of, changes) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            {
                publication.id, publication.resource, publication.actor,
                publication.capability, publication.correlationId,
                publication.idempotencyKey, publication.rollbackOf,
                json.encode(publication.changes),
            }), 'writing the publication record')
    end

    local function toPublication(row)
        if not row then return nil end
        return {
            id = row.id,
            resource = row.resource,
            actor = row.actor,
            capability = row.capability,
            correlationId = row.correlation_id,
            idempotencyKey = row.idempotency_key,
            rollbackOf = row.rollback_of,
            changes = decode(row.changes) or {},
            publishedAt = row.published_at,
        }
    end

    function self.publicationByIdempotencyKey(key)
        if not key then return nil end
        local rows = unwrap(
            db.query('SELECT * FROM nxc_config_publications WHERE idempotency_key = ?', { key }),
            'reading a publication by idempotency key')
        return toPublication(rows[1])
    end

    function self.publication(id)
        local rows = unwrap(
            db.query('SELECT * FROM nxc_config_publications WHERE id = ?', { id }),
            'reading a publication')
        return toPublication(rows[1])
    end

    function self.publications(resource, limit)
        local sql = 'SELECT * FROM nxc_config_publications'
        local params = {}
        if resource then
            sql = sql .. ' WHERE resource = ?'; params[#params + 1] = resource
        end
        -- Newest first, matching the in-memory store. Every caller wants the
        -- recent ones, and reversing per call site is how one of them forgets.
        sql = sql .. ' ORDER BY published_at DESC, id DESC'
        if limit then
            sql = sql .. ' LIMIT ?'; params[#params + 1] = limit
        end

        local rows = unwrap(db.query(sql, params), 'reading publications')
        local out = {}
        for _, row in ipairs(rows) do out[#out + 1] = toPublication(row) end
        return out
    end

    --- Persist a registered schema.
    ---
    --- So the administration interface can list a stopped resource's settings.
    --- A resource being down is when an operator most wants to look at its
    --- configuration.
    function self.saveSchema(resource, fields)
        local statements = {
            {
                -- Removed first: a field deleted between versions must not
                -- linger, or the interface offers a setting nothing reads.
                query = 'DELETE FROM nxc_config_schemas WHERE resource = ?',
                values = { resource },
            },
        }
        for _, field in ipairs(fields) do
            statements[#statements + 1] = {
                query = 'INSERT INTO nxc_config_schemas (resource, config_key, definition) '
                     .. 'VALUES (?, ?, ?)',
                values = { resource, field.key, json.encode(field) },
            }
        end
        unwrap(db.transaction(statements), 'saving a schema')
    end

    function self.counts()
        local v = unwrap(db.query('SELECT COUNT(*) AS n FROM nxc_config_values'), 'counting values')
        local p = unwrap(db.query('SELECT COUNT(*) AS n FROM nxc_config_publications'),
            'counting publications')
        return {
            values = tonumber(v[1] and v[1].n) or 0,
            publications = tonumber(p[1] and p[1].n) or 0,
        }
    end

    return self
end

NxcConfig.MariaDBStore = MariaDBStore
return MariaDBStore
