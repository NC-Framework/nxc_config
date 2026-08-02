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
-- nxc_min_server_build reads UNPINNED because no build has been named (OD-020,
-- blocker B-11). A placeholder that fails a check beats a plausible number that
-- passes one: a pinned version is exactly the kind of value nobody re-derives.
nxc_platform 'gta5_enhanced'
nxc_min_server_build 'UNPINNED'
nxc_legacy_compatibility 'none'

author 'The Nexus Core Framework team'
description 'Authoritative runtime configuration service for Nexus Core: schemas, scopes, drafts, publication, audit, rollback.'
version '0.1.0'

-- No script blocks are declared yet: this resource has no code, and a manifest
-- that declares files which do not exist is a lie the server may tolerate and a
-- reviewer will not notice. Blocks are added as each directory gains files.

dependencies {
    'nxc_lib',
    'nxc_core',
    'oxmysql',
}
