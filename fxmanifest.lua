fx_version 'cerulean'
game 'gta5'

author 'The Nexus Core Framework team'
description 'Authoritative runtime configuration service for Nexus Core: schemas, scopes, drafts, publication, audit, rollback.'
version '0.1.0'

shared_scripts {
    'shared/*.lua',
}

client_scripts {
    'client/*.lua',
}

server_scripts {
    'server/*.lua',
}

files {
    'locales/*.json',
}

dependencies {
    'nxc_lib',
    'nxc_core',
    'oxmysql',
}
