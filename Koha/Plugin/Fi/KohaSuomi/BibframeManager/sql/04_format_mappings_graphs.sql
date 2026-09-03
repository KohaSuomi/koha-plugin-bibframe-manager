-- Hybrid Plan Phase 4: Format Mappings and Graphs Tables
-- Stores per-format serialized representations and groups resources into graphs.

-- record_format_mappings: Per-format serialized representations
CREATE TABLE IF NOT EXISTS record_format_mappings (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    format_name     ENUM('marc21','bffi','bibframe2','bibframe3') NOT NULL,

    serialized_data MEDIUMBLOB,
    marc_tags_json  JSON,

    version         INT UNSIGNED DEFAULT 1,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id, format_name),
    CONSTRAINT fk_fmt_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- record_graphs: Groups resources into coherent bibliographic descriptions
CREATE TABLE IF NOT EXISTS record_graphs (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    biblio_id       BIGINT UNSIGNED NOT NULL,
    graph_type      VARCHAR(64) DEFAULT 'bibliographic',
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (biblio_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- record_graph_resources: Links resources to graphs with roles
CREATE TABLE IF NOT EXISTS record_graph_resources (
    graph_id        BIGINT UNSIGNED NOT NULL,
    resource_id     BIGINT UNSIGNED NOT NULL,
    role            VARCHAR(64),
    PRIMARY KEY (graph_id, resource_id),
    CONSTRAINT fk_gr_graph FOREIGN KEY (graph_id) REFERENCES record_graphs(id) ON DELETE CASCADE,
    CONSTRAINT fk_gr_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
