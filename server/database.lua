--- Database access for nxc_config: the oxmysql adapter and the migration runner.
---
--- **Why this is not borrowed from nxc_core.** Two reasons, and the second is the
--- one that decided it.
---
--- A FiveM export serialises its arguments and return values, so a provider —
--- which is a table of functions — cannot cross a resource boundary. And loading
--- nxc_core's server modules into this Lua state would bring `NxcCore` with them,
--- so every error this resource raised would be tagged as coming from nxc_core.
--- That is the same class of defect as the logger claiming to be nxc_lib.
---
--- What IS shared is everything with logic in it: `Nxc.Persistence` and
--- `Nxc.Migrations` moved into nxc_lib for exactly this reason. What remains here
--- is translation, which is why it is short.

if not IsDuplicityVersion() then return end

local Database = {}

local RESOURCE = NxcConfig.RESOURCE

local function oxmysql()
    local ok, export = pcall(function() return exports.oxmysql end)
    if not ok or not export then
        error('oxmysql is not available: it must start before nxc_config', 0)
    end
    return export
end

--- The raw provider. Table ownership is applied by `Nxc.Persistence.scoped`.
Database.provider = {
    query = function(sql, params) return oxmysql():query_async(sql, params or {}) end,
    execute = function(sql, params) return oxmysql():update_async(sql, params or {}) end,
    transaction = function(statements)
        local prepared = {}
        for i, st in ipairs(statements) do
            prepared[i] = { query = st.query, values = st.values or {} }
        end
        return oxmysql():transaction_async(prepared)
    end,
}

---@return boolean, string|nil
function Database.ping()
    local ok, err = pcall(function() return oxmysql():scalar_async('SELECT 1') end)
    if not ok then return false, tostring(err) end
    return true, nil
end

--- Apply this resource's pending migrations.
---
--- Same shape as nxc_core's runner, and the same three rules, which are not
--- obvious and are worth restating where someone will read them:
---
---   Migrations are ENUMERATED in the manifest, not discovered. A .sql file
---   appearing in a folder must not silently become a schema change.
---
---   They are NOT wrapped in a transaction. MySQL implicitly commits around
---   every DDL statement, so a transaction here would look atomic in review and
---   silently not be.
---
---   The record row is written only after every statement succeeds, so a
---   half-applied migration stays pending and is retried. That works only
---   because the DDL is idempotent, which MIGRATION_STANDARDS requires.
---
---@return NxcResult
function Database.migrate()
    local TABLE = 'nxc_migrations'

    local count = GetNumResourceMetadata(RESOURCE, 'nxc_migration')
    local files = {}
    for i = 0, count - 1 do
        local path = GetResourceMetadata(RESOURCE, 'nxc_migration', i)
        local sql = LoadResourceFile(RESOURCE, path)
        if not sql then
            return Nxc.Result.err(Nxc.Errors.new(
                'NXC_CONFIG_MIGRATION_MISSING',
                ('the manifest declares migration %s, which does not exist'):format(path),
                { resource = RESOURCE }))
        end
        files[#files + 1] = { filename = path:match('([^/]+)$') or path, sql = sql }
    end
    if #files == 0 then return Nxc.Result.ok({ applied = {} }) end

    local planned = Nxc.Migrations.plan(files)
    if not planned.ok then return planned end

    -- Scoped to this resource. nxc_migrations is shared by every resource that
    -- migrates, and reading the whole table would mean treating another
    -- resource's migrations as our own.
    local readOk, rows = pcall(function()
        return Database.provider.query(
            ('SELECT migration, checksum FROM `%s` WHERE resource = ? ORDER BY id'):format(TABLE),
            { RESOURCE })
    end)
    if not readOk then
        return Nxc.Result.err(Nxc.Errors.new(
            'NXC_CONFIG_MIGRATION_TABLE_MISSING',
            ('cannot read `%s`: %s. The deployment recipe creates this table'):format(
                TABLE, tostring(rows)),
            { resource = RESOURCE }))
    end

    local plan = Nxc.Migrations.pending(planned.value, rows or {}, RESOURCE)
    if not plan.ok then return plan end

    local done = {}
    for _, migration in ipairs(plan.value.pending) do
        Nxc.Logger.info('migration.applying', { migration = migration.filename })

        local statements = Nxc.Migrations.statements(migration.sql)
        local completed = 0
        local ok, err = pcall(function()
            for _, statement in ipairs(statements) do
                Database.provider.execute(statement, {})
                completed = completed + 1
            end
        end)
        if not ok then
            return Nxc.Result.err(Nxc.Errors.new(
                'NXC_CONFIG_MIGRATION_FAILED',
                ('Migration %s failed at statement %d of %d.')
                    :format(migration.filename, completed + 1, #statements),
                { resource = RESOURCE, details = {
                    migration = migration.filename, reason = tostring(err),
                    statementsApplied = completed, recorded = false } }))
        end

        local recorded, recordErr = pcall(function()
            Database.provider.execute(
                ('INSERT INTO `%s` (resource, migration, checksum) VALUES (?, ?, ?)'):format(TABLE),
                { RESOURCE, migration.filename, migration.checksum })
        end)
        if not recorded then
            return Nxc.Result.err(Nxc.Errors.new(
                'NXC_CONFIG_MIGRATION_UNRECORDED',
                ('Migration %s applied but could not be recorded.'):format(migration.filename),
                { resource = RESOURCE, details = { reason = tostring(recordErr),
                                                   checksum = migration.checksum } }))
        end
        done[#done + 1] = migration.filename
    end

    return Nxc.Result.ok({ applied = done })
end

NxcConfig.Database = Database
return Database
