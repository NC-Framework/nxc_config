-- nxc_config — schemas, values, and publications.
--
-- Three tables, all owned by nxc_config. No other resource writes them, and
-- nxc_config writes no other resource's tables.
--
-- Reversible: yes, by dropping the three. Destructive: no — it creates only.
-- Expected duration: instant on any realistic size.

-- ----------------------------------------------------------------- schemas
-- What each resource declared it can be configured with.
--
-- Stored rather than held only in memory so the administration interface can
-- list settings for a resource that is currently stopped. A resource being down
-- is when an operator most wants to look at its configuration.
--
-- The definition is kept as JSON. The alternative is fourteen columns that must
-- change whenever MDD 37.5 gains a property, and the authoritative copy is the
-- declaration in the resource's own code either way — this is a cache of it.
CREATE TABLE IF NOT EXISTS `nxc_config_schemas` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `resource`      VARCHAR(64)     NOT NULL,
    `config_key`    VARCHAR(191)    NOT NULL,
    `definition`    JSON            NOT NULL,
    `registered_at` DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    -- One definition per key. Re-registration replaces rather than accumulates.
    UNIQUE KEY `uq_resource_key` (`resource`, `config_key`),
    KEY `idx_resource` (`resource`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

-- ------------------------------------------------------------ publications
-- Who changed what, when, and under which capability.
--
-- Written before the values that belong to it, so a foreign key can point the
-- right way: a value cannot exist without the publication that set it.
CREATE TABLE IF NOT EXISTS `nxc_config_publications` (
    `id`              VARCHAR(32)  NOT NULL,
    `resource`        VARCHAR(64)  NOT NULL,
    `actor`           VARCHAR(32)      NULL,
    `capability`      VARCHAR(64)      NULL,
    `correlation_id`  VARCHAR(64)      NULL,
    -- A retried publication must not publish twice (directive 16.4). The unique
    -- constraint is what makes that true under concurrency; an application check
    -- alone has a race in it.
    `idempotency_key` VARCHAR(128)     NULL,
    `rollback_of`     VARCHAR(32)      NULL,
    `changes`         JSON         NOT NULL,
    `published_at`    DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_idempotency` (`idempotency_key`),
    KEY `idx_resource_time` (`resource`, `published_at`),
    -- Self-referential and nullable: a rollback names what it undid, and most
    -- publications are not rollbacks.
    CONSTRAINT `fk_publication_rollback_of`
        FOREIGN KEY (`rollback_of`) REFERENCES `nxc_config_publications` (`id`)
        ON DELETE SET NULL
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

-- ------------------------------------------------------------------ values
-- Published values, appended and never updated.
--
-- THIS TABLE ONLY GROWS. That is the design, not an oversight: values are
-- versioned by publication so that rollback selects an earlier state rather than
-- re-editing to what someone remembers. Retention is an open question in
-- ADR-0013 and a real one — this needs an archival policy before a server has
-- years of history.
--
-- The current value for a key at a scope is the newest row for it, which is why
-- the read index is ordered by id.
CREATE TABLE IF NOT EXISTS `nxc_config_values` (
    `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `publication_id` VARCHAR(32)     NOT NULL,
    `resource`       VARCHAR(64)     NOT NULL,
    `config_key`     VARCHAR(191)    NOT NULL,
    `scope`          VARCHAR(32)     NOT NULL,
    -- NULL for scopes that identify no subject: global, environment, resource.
    `scope_id`       VARCHAR(64)         NULL,
    -- JSON so a value keeps its type. A boolean stored as '1' comes back as a
    -- string and compares unequal to the boolean it was, which is the kind of
    -- defect that surfaces as a setting that will not turn off.
    `value`          JSON            NOT NULL,
    `applied_at`     DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    -- Resolution reads every row for a key and takes the newest per scope, so
    -- this is the index that matters.
    KEY `idx_key_scope` (`config_key`, `scope`, `scope_id`, `id`),
    KEY `idx_resource` (`resource`),
    KEY `idx_publication` (`publication_id`),
    CONSTRAINT `fk_value_publication`
        FOREIGN KEY (`publication_id`) REFERENCES `nxc_config_publications` (`id`)
        ON DELETE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
