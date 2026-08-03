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
--- Read from the manifest so the version is stated ONCE.
---
--- It used to be a literal here as well as in fxmanifest.lua, and they drifted:
--- the manifest said one thing while every log line said another. Two sources of
--- truth for a version is one source of truth and one rumour.
---
--- The fallback is for the test harness, where no natives exist. It is the only
--- place a literal can still be wrong, and there it cannot mislead an operator.
NxcConfig.VERSION = (type(GetResourceMetadata) == 'function'
    and GetResourceMetadata(GetCurrentResourceName(), 'version', 0))
    or '0.0.0-test'

--- Contract version of the surface other resources depend on.
---
--- Incremented when registration, resolution, or the change event changes
--- incompatibly. Consumers assert a bounded range at startup, because each
--- resource loads its own copy of the shared libraries and nothing makes two
--- resources agree on a version.
NxcConfig.CONTRACT_VERSION = 1

return NxcConfig
