# Contributing

Read these first, in the governance repository `NC-Framework/nxc-core-governance`:

1. `DEVELOPMENT_PLAN.md` — the execution authority.
2. `CURRENT_STATE.md` — what actually exists.
3. `DEFINITION_OF_DONE.md` — the bar for calling anything finished. It is enforced.
4. The standards for the area you are touching.

## Before you commit

```bash
npm test
```

## Commits

```text
type(scope): summary [NXC-P1-002]
```

Every commit references a development-plan task ID. Unrelated changes are never combined into one
commit. No tool-provenance text, no co-author trailers.

## What will not be accepted

Placeholders. Stubs. Commented future implementations. Hardcoded happy paths. Client-side checks
standing in for server checks. Tests that assert a function was called rather than what it did.
Documentation describing behavior that does not exist.
