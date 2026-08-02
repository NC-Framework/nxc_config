# Security

## Reporting

**Do not open a public issue for a security vulnerability.** Report privately to the project owner
through the contact channel published for the server.

Include what the vulnerability allows, how to reproduce it, and which resource and version.

## Secrets

A credential committed to this repository is compromised. **Rotate it** — removing the commit does not
un-publish it.

Bootstrap files are committed with blank placeholders only. Real values are supplied on the server, in
`server.cfg` convars or the operator's own copy, and are never committed back.

## Design posture

Security in Nexus Core is architectural rather than a final pass: server authority, schema validation at
every boundary, capability checks at the point of mutation, session binding, idempotency, atomic
operations, rate limits, and audit trails.

A vulnerability report is therefore often a report about a missing structural control rather than a
single bug, and is treated accordingly.
