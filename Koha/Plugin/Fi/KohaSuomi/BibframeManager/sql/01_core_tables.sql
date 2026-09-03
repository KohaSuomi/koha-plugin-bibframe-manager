-- Hybrid Plan Phase 1: Core Storage Layer (Plan B)
-- Canonical source of truth: record_resources, record_properties, record_links
-- These tables store BIBFRAME/WEMI entities in a format-agnostic way.

-- record_resources: Core entity table for all BIBFRAME resources
-- Items link to Koha's items table via item_id (minimal storage, authoritative data in items)
CREATE TABLE IF NOT EXISTS record_resources (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uri             VARCHAR(512) NOT NULL,
    resource_type   ENUM(
        'Work','Expression','Manifestation','Item','Instance',
        'Agent','Person','Organization','Meeting','Family',
        'Topic','GenreForm','Geographic','Temporal',
        'Title','Place','Language','Series','AdminMetadata'
    ) NOT NULL,
    biblio_id       BIGINT UNSIGNED,
    item_id         BIGINT UNSIGNED,      -- nullable: links to Koha items.itemnumber for Item resources

    label           VARCHAR(1024),
    label_normalized VARCHAR(1024),

    source_format   ENUM('marc21','bibframe','bffi','manual','imported') DEFAULT 'manual',
    source_record   BIGINT UNSIGNED,

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (uri),
    KEY (resource_type),
    KEY (biblio_id),
    KEY (item_id),
    KEY (label_normalized(191)),
    KEY (source_format)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- record_properties: EAV property storage for all resource attributes
CREATE TABLE IF NOT EXISTS record_properties (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    property_uri    VARCHAR(512) NOT NULL,
    property_key    VARCHAR(128) NOT NULL,

    value_type      ENUM('literal','resource','bnode') NOT NULL,
    value_text      TEXT,
    value_normalized TEXT,
    value_datatype  VARCHAR(256),
    value_lang      VARCHAR(32),
    value_resource_id BIGINT UNSIGNED,

    sequence        SMALLINT UNSIGNED DEFAULT 0,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    KEY (resource_id),
    KEY (property_key),
    KEY (property_uri(191)),
    KEY (value_text(191)),
    KEY (value_resource_id),
    CONSTRAINT fk_prop_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_prop_value_res FOREIGN KEY (value_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- record_links: Relationships between resources
CREATE TABLE IF NOT EXISTS record_links (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    source_resource_id  BIGINT UNSIGNED NOT NULL,
    target_resource_id  BIGINT UNSIGNED NOT NULL,
    relationship_type   VARCHAR(128) NOT NULL,
    relationship_uri    VARCHAR(512),
    sequence            SMALLINT UNSIGNED DEFAULT 0,
    properties_json     JSON,

    UNIQUE KEY (source_resource_id, target_resource_id, relationship_type),
    KEY (target_resource_id),
    KEY (relationship_type),
    CONSTRAINT fk_link_source FOREIGN KEY (source_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_link_target FOREIGN KEY (target_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
