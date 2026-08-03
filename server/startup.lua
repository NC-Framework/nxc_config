--- Startup orchestration.
---
--- Same shape as nxc_core's, for the same reason: a resource that defines
--- everything and runs none of it reports "Started" and does nothing, which is
--- the failure mode with no error to read.
---
---   1. Assert the library contract. Refuse to run against a stale nxc_lib.
---   2. Reach the database.
---   3. Apply migrations.
---   4. Open, and announce readiness so resources register.
---
--- **A failure at any step stops the service rather than degrading it.** A
--- configuration service that starts without its database would hand every
--- resource its defaults and look correct while quietly discarding every setting
--- an operator has ever published.

if not IsDuplicityVersion() then return end

local Startup = {}

local ready, failure = false, nil

---@return boolean
function Startup.isReady() return ready end

local function halt(headline, err)
    ready, failure = false, err
    print('^1')
    print('^1========================================================================^7')
    print('^1 NXC_CONFIG DID NOT START^7')
    print('^1========================================================================^7')
    print('^1 ' .. headline .. '^7')
    if err and err.message then print('^1 ' .. tostring(err.message) .. '^7') end
    if err and err.details and err.details.reason then
        print('^1 ' .. tostring(err.details.reason) .. '^7')
    end
    print('^1========================================================================^7')
    print('^1')
    if Nxc.Health then Nxc.Health.fail(headline) end
end

CreateThread(function()
    Wait(0)

    Nxc.Logger.setResource(NxcConfig.RESOURCE)

    ------------------------------------------------------- 1. library contract
    -- Every resource loads its own copy of nxc_lib, so this one is whichever was
    -- on disk when nxc_config was last deployed. Bounded at both ends:
    -- CONTRACT_VERSION increments on incompatible change, so a newer library is
    -- not automatically a safer one.
    --
    -- v3 is the minimum: Nxc.Persistence and Nxc.Migrations arrived in v2, and
    -- Nxc.plain in v3. Against an older copy this resource would fail at whatever
    -- line first reached them, naming a symptom rather than the cause.
    local LIB_MIN, LIB_MAX = 3, 3
    if type(Nxc) ~= 'table' or not Nxc.CONTRACT_VERSION
        or Nxc.CONTRACT_VERSION < LIB_MIN or Nxc.CONTRACT_VERSION > LIB_MAX then
        return halt('nxc_lib is not a version this nxc_config supports.', {
            message = ('nxc_config supports nxc_lib contract v%d to v%d; the installed copy is v%s.')
                :format(LIB_MIN, LIB_MAX, tostring(type(Nxc) == 'table' and Nxc.CONTRACT_VERSION)),
            details = { reason = 'Reinstall the compatibility set rather than individual resources. '
                              .. 'Run nxc_versions in this console to see what is installed.' },
        })
    end

    ------------------------------------------------------------- 2. database
    -- Waiting for oxmysql rather than for nxc_core. This resource owns its own
    -- three tables and reaches the database directly, because a provider is a
    -- table of functions and a FiveM export cannot carry one across a resource
    -- boundary.
    --
    -- nxc_core remains a dependency for its contracts, not for its connection.
    local reachable, pingErr
    local waited = 0
    repeat
        reachable, pingErr = NxcConfig.Database.ping()
        if not reachable then Wait(250); waited = waited + 250 end
    until reachable or waited >= 15000

    if not reachable then
        return halt('The database is unreachable.', {
            message = 'nxc_config cannot run without its database.',
            details = { reason = tostring(pingErr) },
        })
    end

    Nxc.Persistence.setProvider(NxcConfig.Database.provider)
    local scoped = Nxc.Persistence.scoped(NxcConfig.RESOURCE)
    Nxc.Logger.info('startup.database_ready', {})

    ---------------------------------------------------------- 3. migrations
    local migrated = NxcConfig.Database.migrate()
    if not migrated.ok then
        return halt('A database migration failed.', migrated.error)
    end
    if #migrated.value.applied > 0 then
        Nxc.Logger.info('startup.migrations_applied', {
            count = #migrated.value.applied,
            migrations = migrated.value.applied,
        })
    end

    ---------------------------------------------------------------- 4. open
    NxcConfig.Service.open(NxcConfig.MariaDBStore.create(scoped))
    ready, failure = true, nil

    Nxc.Logger.info('startup.ready', {
        version = NxcConfig.VERSION,
        contractVersion = NxcConfig.CONTRACT_VERSION,
    })
    print(('^2[nxc_config]^7 ready — v%s, contract v%d')
        :format(NxcConfig.VERSION, NxcConfig.CONTRACT_VERSION))
end)

--- `nxc_config_status` — what is registered and what is set.
---
--- Console only: it reports internal state, and MDD v0.4 38.8 forbids exposing
--- development tooling globally in production.
RegisterCommand('nxc_config_status', function(source)
    if source ~= 0 then return end

    print(('^5[nxc_config]^7 %s'):format(ready and '^2ready^7' or '^1NOT READY^7'))
    if failure then print(('  failure: %s'):format(tostring(failure.message or failure))) end

    local resources = NxcConfig.Registry.resources()
    print(('  registered resources  %d'):format(#resources))
    for _, resource in ipairs(resources) do
        local fields = NxcConfig.Registry.fields(resource)
        print(('    %-16s %d fields'):format(resource, #fields))
    end

    local store = NxcConfig.Service.store()
    if store then
        local ok, counts = pcall(store.counts)
        if ok then
            print(('  published values      %d'):format(counts.values))
            print(('  publications          %d'):format(counts.publications))
        end
    end
end, true)

NxcConfig.Startup = Startup
return Startup
