-- Hybrid Plan Phase 2: Summary Tables (Plan A-style)
-- Derived from core storage for fast reads of common query patterns.
-- These tables are rebuilt when data changes in the core tables.

-- record_work_summary: Fast access to Work-level data
CREATE TABLE IF NOT EXISTS record_work_summary (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    biblio_id       BIGINT UNSIGNED,

    title           VARCHAR(1024),
    title_normalized VARCHAR(1024),
    language        VARCHAR(32),
    work_type       VARCHAR(128),

    original_language  VARCHAR(32),
    original_resource_id BIGINT UNSIGNED NULL,
    original_pending   TINYINT DEFAULT 0,
    original_external_id  VARCHAR(512),
    original_external_source VARCHAR(128),

    contributor_count   INT UNSIGNED DEFAULT 0,
    subject_count       INT UNSIGNED DEFAULT 0,
    instance_count      INT UNSIGNED DEFAULT 0,

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id),
    KEY (biblio_id),
    KEY (title_normalized(191)),
    KEY (language),
    KEY (original_language),
    KEY (work_type),
    CONSTRAINT fk_ws_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_ws_orig FOREIGN KEY (original_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- record_instance_summary: Fast access to Instance-level data
-- The LoC BIBFRAME 3-level model is the canonical stored model (Work -> Instance -> Item),
-- so the physical-entity summary is keyed on Instance rather than Manifestation.
CREATE TABLE IF NOT EXISTS record_instance_summary (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id         BIGINT UNSIGNED NOT NULL,
    work_resource_id    BIGINT UNSIGNED,
    biblio_id           BIGINT UNSIGNED,

    publisher_name      VARCHAR(512),
    publication_place   VARCHAR(255),
    publication_date    VARCHAR(128),
    publication_date_sort DATE,

    instance_type       VARCHAR(128),
    media_type          VARCHAR(128),
    carrier_type        VARCHAR(128),
    extent              VARCHAR(512),

    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id),
    KEY (work_resource_id),
    KEY (biblio_id),
    KEY (publication_date_sort),
    KEY (publisher_name(191)),
    KEY (instance_type),
    KEY (carrier_type),
    CONSTRAINT fk_ms_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_ms_work FOREIGN KEY (work_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- record_agent_summary: Fast access to Agent data for authority browsing
CREATE TABLE IF NOT EXISTS record_agent_summary (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    agent_type      ENUM('Person','Organization','Meeting','Family') NOT NULL,
    name            VARCHAR(1024) NOT NULL,
    name_normalized VARCHAR(1024),
    work_count      INT UNSIGNED DEFAULT 0,

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id),
    KEY (agent_type),
    KEY (name(191)),
    KEY (name_normalized(191)),
    CONSTRAINT fk_as_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
