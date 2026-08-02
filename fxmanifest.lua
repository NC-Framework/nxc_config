fx_version 'cerulean'
game 'gta5'

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
