-- Hybrid Plan Phase 3: Component Parts Table
-- Specialized table for MARC21 773/774 <-> BIBFRAME partOf/hasPart linking
-- Uses typed-column approach for fast queries on articles, chapters, issues.

CREATE TABLE IF NOT EXISTS record_component_parts (
    id                      BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    component_resource_id   BIGINT UNSIGNED NOT NULL,
    host_resource_id        BIGINT UNSIGNED,

    relationship_type       VARCHAR(128) NOT NULL,
    relationship_label      VARCHAR(512),
    relationship_info       VARCHAR(512),

    volume_designation      VARCHAR(255),

    host_title              VARCHAR(1024),
    host_issn               VARCHAR(32),
    host_control_number     VARCHAR(128),
    host_uri                VARCHAR(512),

    source_marc_tag         VARCHAR(4),
    source_marc_subfields   JSON,

    created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    KEY (component_resource_id),
    KEY (host_resource_id),
    KEY (host_issn),
    KEY (relationship_type),
    CONSTRAINT fk_rcp_component FOREIGN KEY (component_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_rcp_host FOREIGN KEY (host_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
