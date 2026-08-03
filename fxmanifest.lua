fx_version 'cerulean'
game 'gta5'

-- Platform target. MDD v0.4 section 38.3 requires every resource to declare its
-- Enhanced compatibility in its manifest; ADR-0016 records the decision.
--
-- These are first-party metadata keys rather than CitizenFX directives. An
-- arbitrary top-level key becomes resource metadata readable through
-- GetResourceMetadata, so the mechanism is supported; whether the platform
-- offers an official directive for this has not been verified, and is open as
-- OD-021 rather than assumed either way.
--
-- nxc_min_server_build is the Enhanced Cfx Server build this was first deployed
-- against, reported as `b106-ea` on 2026-08-02. OD-020 and blocker B-11 closed.
--
-- NOT expressed as a `/server:106` dependency constraint, which is the mechanism
-- the platform enforces. That constraint compares build numbers, and Legacy
-- numbers them far HIGHER — around 25770 — so `/server:106` passes trivially on
-- Legacy and guards nothing. It is added when a resource actually needs a
-- specific Enhanced build, where it would buy something.
nxc_platform 'gta5_enhanced'
nxc_min_server_build '106'
nxc_legacy_compatibility 'none'

author 'The Nexus Core Framework team'
description 'Authoritative runtime configuration service for Nexus Core: schemas, scopes, drafts, publication, audit, rollback.'
version '0.1.0'

-- Scripts are ENUMERATED, in load order, rather than globbed. A glob sorts
-- alphabetically, which is not dependency order.
--
-- nxc_lib's modules are loaded INTO this resource's Lua state through the
-- `@resource/path` form. Every FiveM resource has its own state, so declaring
-- nxc_lib as a dependency orders startup and shares no code at all.
shared_scripts {
    '@nxc_lib/shared/namespace.lua',
    '@nxc_lib/shared/result.lua',
    '@nxc_lib/shared/errors.lua',
    '@nxc_lib/shared/correlation.lua',
    '@nxc_lib/shared/time.lua',
    '@nxc_lib/shared/serialize.lua',
    '@nxc_lib/shared/validate.lua',
    '@nxc_lib/shared/envelope.lua',
    '@nxc_lib/shared/ratelimit.lua',
    '@nxc_lib/shared/cancel.lua',
    '@nxc_lib/shared/logger.lua',
    '@nxc_lib/shared/locale.lua',
    '@nxc_lib/shared/permissions.lua',
    '@nxc_lib/shared/health.lua',
    '@nxc_lib/shared/config_schema.lua',

    'shared/namespace.lua',
    'shared/scopes.lua',
    'shared/registry.lua',
    'shared/store.lua',
    'shared/drafts.lua',
    'shared/publication.lua',
}

dependencies {
    'nxc_lib',
    'nxc_core',
    'oxmysql',
}
