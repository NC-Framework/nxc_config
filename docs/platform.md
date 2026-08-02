# Platform — nxc_config

**Target:** FiveM for GTA V Enhanced, Enhanced Cfx Server runtime.

Required by Master Design Document v0.4 section 38.3 and
[`PLATFORM_STANDARDS.md`](https://github.com/NC-Framework/nxc-core-governance/blob/main/standards/PLATFORM_STANDARDS.md).
All eight items are answered. **`None` is written where it applies** — an empty section is a claim that
someone looked and found nothing, and an absent section is not.

`nxc_config` is the authoritative runtime configuration service: schemas, scopes, drafts, publication, audit, and rollback.

---

### 1. Enhanced natives and platform APIs used

**None — this resource has no code yet.**

That is a statement about the present, not a claim about the design. The platform surface will be recorded as it is written.

### 2. Deprecated or compatibility-only natives used

**None.**

### 3. Game assets, archetypes, metadata, or data files required

**None currently.**

### 4. Voice, networking, state bag, entity, and routing bucket assumptions

**Not yet determined.** Configuration publication will need a change event reaching clients; whether that is a network event or a state bag is a design decision that has not been made.

Routing buckets, when needed, are **requested from `nxc_core`**, never chosen. Two resources picking the
same number is the accidental-instance failure the design names as an existing production problem.

### 5. Known Enhanced platform limitations

**None known, and none have been looked for.** Nothing has been tested on Enhanced, because the
development server runs Legacy artifacts (blocker B-10).

### 6. Minimum supported Cfx Server build

**Not pinned.** No build has been named — OD-020, blocker B-11. The manifest declares `UNPINNED`, which
fails `check-manifests.mjs` deliberately rather than passing with a plausible-looking number.

### 7. Asset conversion or validation requirements

**None.**

### 8. Optional Legacy compatibility layer

**None**, and none is planned. Legacy support is not a launch requirement (ADR-0016).
