--- nxc_config — the authoritative configuration service.
---
--- Every Nexus Core resource registers its operational configuration here and
--- exposes a permission-controlled in-game management surface. MDD section 37.10
--- makes that a condition of acceptance rather than a quality goal.
---
--- **Under ADR-0018 this resource carries more weight than its size suggests.**
--- Nexus Core is distributed to servers it was not written for, and configuration
--- is the entire mechanism by which one framework fits many servers. A value that
--- is not configurable is a decision imposed on every operator.
---
--- What lives here: schema registration, scope precedence, drafts, publication,
--- audit, and rollback. What does not: any resource's actual settings. This
--- service holds no opinion about what a good character limit is.

NxcConfig = NxcConfig or {}

NxcConfig.RESOURCE = 'nxc_config'
NxcConfig.VERSION = '0.1.0'

--- Contract version of the surface other resources depend on.
---
--- Incremented when registration, resolution, or the change event changes
--- incompatibly. Consumers assert a bounded range at startup, because each
--- resource loads its own copy of the shared libraries and nothing makes two
--- resources agree on a version.
NxcConfig.CONTRACT_VERSION = 1

return NxcConfig
