# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

## Unreleased

### Added

- Scope precedence resolution: `default → environment → global → resource → organization →
  location → player`, lowest to highest. Pure — values in, effective value out — so the
  precedence rules are testable without a database.
- Resolution reports what was **overridden**, not only what won, so a management screen can
  explain why a setting is what it is.
- Schema registration with all fourteen required field properties enforced, keys namespaced
  to the registering resource, and a rejected schema storing nothing rather than half of
  itself.
- 29 tests across 6 suites, including the real `nxc_core` schema registering unchanged.

Initial development. No release has been made.
