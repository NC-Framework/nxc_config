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
- A value store where **values are versioned by publication, never overwritten**, which is
  what makes rollback a first-class operation rather than a manual redo.
- Drafts with validation and an impact preview that answers the restart question **before**
  publishing rather than after.
- Publication: atomic, idempotent, audited. The change event carries **keys and reload
  behaviour, never values**.
- Rollback as a forward operation — it publishes the prior values and does not delete
  history.
- Four capabilities, scoped per resource. **A sensitive value never leaves the server, for
  anyone**, because a management screen shows that a secret is set, not what it is.
- 69 tests across 14 suites, including the real `nxc_core` schema registering unchanged.

Initial development. No release has been made.
