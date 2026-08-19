# Hybrid Plan: Combining Format-Agnostic Storage with Typed Performance

**Date:** 2026-08-17
**Status:** Design Document
**Author:** Johanna Räisä (assisted by opencode/big-pickle LLM)
**Source:** `ANALYSIS_FORMAT_AGNOSTIC_SCHEMA.md` (Plan B) + `ANALYSIS_BIBFRAME_TABLE_STRUCTURE.md` (Plan A)

---

## Table of Contents

1. [Why Hybrid?](#why-hybrid)
2. [Architecture Overview](#architecture-overview)
3. [Core Storage Layer (Plan B)](#core-storage-layer-plan-b)
4. Summary Tables (Plan A)
5. Component Parts Table (Plan A)
6. Format Mappings Table (Plan B)
7. Elasticsearch Integration
8. Data Flow
9. Query Examples
10. Implementation Phases

---

## Why Hybrid?

Plan A (typed columns) is fast but rigid. Plan B (EAV) is flexible but slow. The hybrid uses **Plan B as the canonical source** and **Plan A tables as materialized summaries** for the most common query patterns.

```
┌─────────────────────────────────────────────────────────┐
│              EXPORT LAYER                                │
│  MARC21 Generator ← Summary tables (fast reads)         │
│  BIBFRAME Generator ← Core tables (full graph)          │
├─────────────────────────────────────────────────────────┤
│              SUMMARY LAYER (Plan A-style)                │
│  record_work_summary    (title, language, date)         │
│  record_manif_summary   (publisher, format, identifiers)│
│  record_component_parts (host ↔ component linking)      │
│  record_agent_summary   (name, role counts)             │
├─────────────────────────────────────────────────────────┤
│              CANONICAL STORAGE LAYER (Plan B)            │
│  record_resources ← record_properties ← record_links    │
├─────────────────────────────────────────────────────────┤
│              ELASTICSEARCH                                │
│  Built from summary tables (fast) + core tables (full)  │
└─────────────────────────────────────────────────────────┘
```

**Key principle:** Summary tables are **derived, not authoritative**. They are rebuilt from the core tables when data changes.

---

## Architecture Overview

| Layer | Source | Purpose |
|-------|--------|---------|
| **Canonical Storage** | `record_resources`, `record_properties`, `record_links` | Format-agnostic source of truth. Any format can be stored and exported. |
| **Summary Tables** | `record_work_summary`, `record_manif_summary` | Fast reads for common queries. Derived from canonical storage. |
| **Component Parts** | `record_component_parts` | Specialized table for MARC21 773/774 ↔ BIBFRAME partOf/hasPart linking. |
| **Format Mappings** | `record_format_mappings` | Per-format serialized representations (MARC21, BIBFRAME RDF). |
| **Graphs** | `record_graphs`, `record_graph_resources` | Groups resources into coherent bibliographic descriptions. |
| **Elasticsearch** | Derived from summary + core tables | Search and discovery. Never the source of truth. |

---

## Core Storage Layer (Plan B)

These tables are the **canonical source of truth**. All data flows in and out through them.

### record_resources

```sql
CREATE TABLE record_resources (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uri             VARCHAR(512) NOT NULL,
    resource_type   ENUM(
        'Work','Expression','Manifestation','Item','Instance',
        'Agent','Person','Organization','Meeting','Family',
        'Topic','GenreForm','Geographic','Temporal',
        'Title','Place','Language','Series','AdminMetadata'
    ) NOT NULL,
    biblio_id       BIGINT UNSIGNED,      -- nullable for shared entities (agents, subjects)

    label           VARCHAR(1024),        -- human-readable label
    label_normalized VARCHAR(1024),       -- NACO-normalized for dedup

    source_format   ENUM('marc21','bibframe','bffi','manual','imported') DEFAULT 'manual',
    source_record   BIGINT UNSIGNED,      -- original biblio if imported

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (uri),
    KEY (resource_type),
    KEY (biblio_id),
    KEY (label_normalized(191)),
    KEY (source_format)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### record_properties

```sql
CREATE TABLE record_properties (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    property_uri    VARCHAR(512) NOT NULL,
    property_key    VARCHAR(128) NOT NULL,  -- shorthand: 'mainTitle', 'language', etc.

    value_type      ENUM('literal','resource','bnode') NOT NULL,
    value_text      TEXT,
    value_normalized TEXT,
    value_datatype  VARCHAR(256),           -- xsd:dateTime, xsd:integer, etc.
    value_lang      VARCHAR(32),
    value_resource_id BIGINT UNSIGNED,      -- FK to record_resources.id

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
```

### record_links

```sql
CREATE TABLE record_links (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    source_resource_id  BIGINT UNSIGNED NOT NULL,
    target_resource_id  BIGINT UNSIGNED NOT NULL,
    relationship_type   VARCHAR(128) NOT NULL,  -- 'hasExpression','contribution','subject', etc.
    relationship_uri    VARCHAR(512),
    sequence            SMALLINT UNSIGNED DEFAULT 0,
    properties_json     JSON,                   -- additional props on the link itself

    UNIQUE KEY (source_resource_id, target_resource_id, relationship_type),
    KEY (target_resource_id),
    KEY (relationship_type),
    CONSTRAINT fk_link_source FOREIGN KEY (source_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_link_target FOREIGN KEY (target_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Summary Tables (Plan A-style)

These tables are **derived from the core storage** and rebuilt when data changes. They provide fast reads for the most common query patterns.

### record_work_summary

```sql
-- Rebuilt from record_resources + record_properties
-- Provides fast access to Work-level data without EAV pivoting
CREATE TABLE record_work_summary (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,  -- FK to record_resources.id
    biblio_id       BIGINT UNSIGNED,

    title           VARCHAR(1024),
    title_normalized VARCHAR(1024),
    language        VARCHAR(32),
    work_type       VARCHAR(128),

    -- Denormalized from properties for fast queries
    contributor_count   INT UNSIGNED DEFAULT 0,
    subject_count       INT UNSIGNED DEFAULT 0,
    manifestation_count INT UNSIGNED DEFAULT 0,

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id),
    KEY (biblio_id),
    KEY (title_normalized(191)),
    KEY (language),
    KEY (work_type),
    CONSTRAINT fk_ws_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### record_manif_summary

```sql
-- Rebuilt from record_resources + record_properties
-- Provides fast access to Manifestation-level data
CREATE TABLE record_manif_summary (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id         BIGINT UNSIGNED NOT NULL,  -- FK to record_resources.id
    work_resource_id    BIGINT UNSIGNED,           -- FK to record_resources.id (Work)
    biblio_id           BIGINT UNSIGNED,

    publisher_name      VARCHAR(512),
    publication_place   VARCHAR(255),
    publication_date    VARCHAR(128),
    publication_date_sort DATE,

    manifestation_type  VARCHAR(128),  -- 'Print', 'Electronic', 'Microform'
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
    KEY (manifestation_type),
    KEY (carrier_type),
    CONSTRAINT fk_ms_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_ms_work FOREIGN KEY (work_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### record_agent_summary

```sql
-- Rebuilt from record_resources + record_properties
-- Provides fast access to Agent data for authority browsing
CREATE TABLE record_agent_summary (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,  -- FK to record_resources.id
    agent_type      ENUM('Person','Organization','Meeting','Family') NOT NULL,
    name            VARCHAR(1024) NOT NULL,
    name_normalized VARCHAR(1024),             -- NACO-normalized for dedup
    work_count      INT UNSIGNED DEFAULT 0,    -- denormalized count of Works contributed to

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id),
    KEY (agent_type),
    KEY (name(191)),
    KEY (name_normalized(191)),
    CONSTRAINT fk_as_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Component Parts Table (Plan A)

Component parts (articles, chapters, issues) are the most common query pattern requiring typed columns. See `ANALYSIS_COMPONENT_PARTS.md` for full analysis.

```sql
-- Specialized table for MARC21 773/774 ↔ BIBFRAME partOf/hasPart linking
-- Uses Plan A's typed-column approach for fast queries
CREATE TABLE record_component_parts (
    id                      BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    component_resource_id   BIGINT UNSIGNED NOT NULL,  -- FK to record_resources.id
    host_resource_id        BIGINT UNSIGNED,           -- FK to record_resources.id (nullable if host not local)

    relationship_type       VARCHAR(128) NOT NULL,     -- 'partOf','hasPart','supplement','precededBy', etc.
    relationship_label      VARCHAR(512),              -- from $i (display text)
    relationship_info       VARCHAR(512),              -- from $g (relationship information)

    volume_designation      VARCHAR(255),              -- from $v

    -- When the host record doesn't exist locally
    host_title              VARCHAR(1024),             -- from $t
    host_issn               VARCHAR(32),               -- from $x
    host_control_number     VARCHAR(128),              -- from $w (OCoLC etc.)
    host_uri                VARCHAR(512),              -- from $0 or constructed

    -- Provenance for MARC21 round-trip
    source_marc_tag         VARCHAR(4),                -- '773', '774', etc.
    source_marc_subfields   JSON,                      -- full subfield data

    created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    KEY (component_resource_id),
    KEY (host_resource_id),
    KEY (host_issn),
    KEY (relationship_type),
    CONSTRAINT fk_rcp_component FOREIGN KEY (component_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_rcp_host FOREIGN KEY (host_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Format Mappings Table (Plan B)

Stores per-format serialized representations. The same resource can have both a MARC21 and BIBFRAME representation simultaneously.

```sql
CREATE TABLE record_format_mappings (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    format_name     ENUM('marc21','bffi','bibframe2','bibframe3') NOT NULL,

    serialized_data MEDIUMBLOB,              -- full serialized record in this format
    marc_tags_json  JSON,                    -- ["100","245","650",...] (for MARC21)

    version         INT UNSIGNED DEFAULT 1,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id, format_name),
    CONSTRAINT fk_fmt_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Graphs Table (Plan B)

Groups resources into coherent bibliographic descriptions.

```sql
CREATE TABLE record_graphs (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    biblio_id       BIGINT UNSIGNED NOT NULL,
    graph_type      VARCHAR(64) DEFAULT 'bibliographic',
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (biblio_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE record_graph_resources (
    graph_id        BIGINT UNSIGNED NOT NULL,
    resource_id     BIGINT UNSIGNED NOT NULL,
    role            VARCHAR(64),  -- 'work','expression','manifestation','item'
    PRIMARY KEY (graph_id, resource_id),
    CONSTRAINT fk_gr_graph FOREIGN KEY (graph_id) REFERENCES record_graphs(id) ON DELETE CASCADE,
    CONSTRAINT fk_gr_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Elasticsearch Integration

ES documents are built from **summary tables** (fast) and **core tables** (full detail).

### Index: record_entities

```json
{
  "biblio_id": 42,
  "work": {
    "uri": "http://urn.fi/URN:NBN:fi:bib:work/42",
    "label": "Suomen historiallinen bibliografia",
    "type": "Work",
    "language": ["fin", "swe"],
    "subjects": [
      {"term": "Suomi -- historia", "type": "Topic", "source": "lcsh"}
    ]
  },
  "agents": [
    {"name": "Hakulinen, Veli", "role": "aut", "agent_id": 789}
  ],
  "manifestation": {
    "publisher": "Suomalaisen Kirjallisuuden Seura",
    "date": "2024",
    "formats": ["print", "electronic"],
    "identifiers": [
      {"type": "isbn", "value": "978-952-123456-7"}
    ]
  },
  "component_parts": {
    "host_title": "Journal of Tolkien research",
    "host_issn": "2373-2043",
    "volume": "vol. 5, no. 2"
  },
  "suggest": {
    "input": ["suomen historiallinen bibliografia", "hakulinen", "veli"],
    "weight": 10
  }
}
```

---

## Data Flow

```
MARC21 Record ──→ MARC Parser ──┐
                                 ├──→ Semantic Normalizer ──→ record_resources ──┬──→ Summary Rebuilder ──→ Summary Tables
BIBFRAME RDF ───→ RDF Parser ───┘    (dedup, extract,       record_properties     │                         record_work_summary
                                      link entities)        record_links          │                         record_manif_summary
                                                                                │                         record_agent_summary
                                                                                │
                                                                                ├──→ Format Generator ──→ MARC21 Export
                                                                                │   (reads summary tables)
                                                                                │
                                                                                ├──→ Format Generator ──→ BIBFRAME Export
                                                                                │   (reads core tables)
                                                                                │
                                                                                ├──→ ES Sync ──→ Elasticsearch
                                                                                │   (reads summary tables)
                                                                                │
                                                                                └──→ Component Parts Sync
                                                                                    (reads record_links)
```

### Writing Data

1. **MARC21 → Storage:** Parse MARC21, create `record_resources` + `record_properties` + `record_links`. Store MARC21 in `record_format_mappings`. Rebuild summary tables.

2. **BIBFRAME → Storage:** Parse RDF, create `record_resources` + `record_properties` + `record_links`. Store BIBFRAME in `record_format_mappings`. Rebuild summary tables.

### Reading Data

1. **Common queries:** Read from summary tables (fast). Example: `SELECT * FROM record_work_summary WHERE language = 'fin'`.

2. **Full graph:** Read from core tables. Example: traverse `record_links` to build the complete Work → Expression → Manifestation → Item chain.

3. **Export to MARC21:** Read summary tables + `record_component_parts` + `record_format_mappings`. Reconstruct MARC21 tags/subfields.

4. **Export to BIBFRAME:** Read core tables. Build RDF triples from `record_resources` + `record_properties` + `record_links`.

---

## Query Examples

### "Find all Works by author X" (fast — uses summary tables)

```sql
SELECT w.id, w.title, w.biblio_id
FROM record_work_summary w
JOIN record_agent_summary a ON /* via record_links */
WHERE a.name_normalized LIKE '%hakulinen%';
```

### "Find all Manifestations published in Helsinki in 2024" (fast — uses summary tables)

```sql
SELECT m.id, m.resource_id, m.biblio_id
FROM record_manif_summary m
WHERE m.publication_place = 'Helsinki'
  AND m.publication_date_sort >= '2024-01-01'
  AND m.publication_date_sort < '2025-01-01';
```

### "Find all articles in Journal X" (fast — uses component_parts table)

```sql
SELECT r.id, r.uri, r.label
FROM record_component_parts cp
JOIN record_resources r ON cp.component_resource_id = r.id
WHERE cp.host_title LIKE '%Journal of Tolkien research%'
  AND cp.relationship_type = 'partOf';
```

### "Find the complete graph for biblio_id 42" (full — uses core tables)

```sql
-- Get the graph
SELECT gr.role, r.uri, r.resource_type, r.label
FROM record_graphs g
JOIN record_graph_resources gr ON g.id = gr.graph_id
JOIN record_resources r ON gr.resource_id = r.id
WHERE g.biblio_id = 42;

-- Get all properties for each resource in the graph
SELECT p.property_key, p.value_text, p.value_lang
FROM record_properties p
WHERE p.resource_id IN (/* resource IDs from above */);

-- Get all links between resources in the graph
SELECT l.relationship_type, l.properties_json
FROM record_links l
WHERE l.source_resource_id IN (/* resource IDs from above */);
```

---

## Implementation Phases

| Phase | What | Description |
|-------|------|-------------|
| 1 | Core tables DDL | Create `record_resources`, `record_properties`, `record_links` |
| 2 | Summary tables DDL | Create `record_work_summary`, `record_manif_summary`, `record_agent_summary` |
| 3 | Component parts DDL | Create `record_component_parts` |
| 4 | Format mappings DDL | Create `record_format_mappings`, `record_graphs`, `record_graph_resources` |
| 5 | Install/upgrade hooks | Add DDL to `BibframeManager.pm` `install()` and `upgrade()` |
| 6 | Semantic normalizer | `Modules/SemanticStore.pm` — converts MARC21/BIBFRAME to semantic primitives |
| 7 | Summary rebuilder | `Modules/SummaryRebuilder.pm` — rebuilds summary tables from core tables |
| 8 | Component parts sync | Populate `record_component_parts` from `record_links` with `relationship_type = 'partOf'` |
| 9 | MARC21 generator | `Modules/MarcGenerator.pm` — semantic store → MARC21 XML |
| 10 | BIBFRAME generator | `Modules/BibframeGenerator.pm` — semantic store → RDF triples |
| 11 | Elasticsearch sync | `Modules/SearchIndex.pm` — MariaDB → ES sync |
| 12 | API updates | `BibframeController.pm` — query summary tables instead of `biblio_metadata` |

---

## Summary: What We Take from Each Plan

| Component | Source | Why |
|-----------|--------|-----|
| Canonical storage (EAV) | Plan B | Format-agnostic source of truth |
| Typed summary tables | Plan A | Fast reads for common queries |
| Component parts table | Plan A | Best pattern for serials/article linking |
| Format mappings | Plan B | Multi-format export without schema changes |
| Graph tables | Plan B | Groups resources into coherent descriptions |
| Shared authority tables | Plan A (via summary) | Agent/subject dedup with fast browsing |
| `biblio_id` naming | Plan A | Koha community convention |
| `record_` prefix | Plan B | Format-agnostic naming |
