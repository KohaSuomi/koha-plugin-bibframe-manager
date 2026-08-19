# BIBFRAME Table Structure Analysis

**Date:** 2026-08-17
**Status:** Analysis / Design Document
**Author:** Johanna Räisä (assisted by opencode/big-pickle LLM)

---

## Table of Contents

1. [Current State](#current-state)
2. [Recommended Architecture](#recommended-architecture)
3. [Core Entity Tables](#core-entity-tables)
4. [Shared Authority Tables](#shared-authority-tables)
5. [Relationship Tables](#relationship-tables)
6. [Elasticsearch Index Design](#elasticsearch-index-design)
7. [Component Part Linking](#component-part-linking-marc21-773774--bibframe-partofhaspart)
8. [Data Linking Architecture](#data-linking-architecture)
9. [Key Design Decisions](#key-design-decisions)
10. [Why This Is Better Than Current Approach](#why-this-is-better-than-current-approach)
11. [Migration Path](#migration-path)

---

## Current State

The plugin stores everything as serialized RDF blobs in Koha's `biblio_metadata` table. This means:

- **No queryable structure** — you can't efficiently search for "all Works by author X" or "all Manifestations in format Y"
- **No entity deduplication** — the same Person agent is duplicated across every Work they contributed to
- **No Elasticsearch integration** — nothing is indexed for search
- **No referential integrity** — links between entities are URI strings, not enforced foreign keys

### Current Data Representation

Every BIBFRAME entity is represented as an RDF triple:

```perl
{
    subject     => 'URI of the subject resource',
    predicate   => 'Property URI connecting subject to object',
    object      => 'Value (literal) or URI (resource)',
    object_type => 'literal' or 'uri',
    datatype    => 'optional XSD datatype URI',
    lang        => 'optional language tag'
}
```

### Current Storage

Serialized to `biblio_metadata` in one of five formats:

| Format | Column `format` | Description |
|--------|----------------|-------------|
| Turtle | `turtle` | Default; compact human-readable RDF |
| JSON-LD | `json-ld` | JSON-based linked data |
| N-Triples | `ntriples` | Line-per-triple format |
| RDF/XML | `rdfxml` | XML serialization |
| JSON | `json` | Structured BIBFRAME JSON (custom) |

Schema column is set to `Bibframe` or `BIBFRAME` (two variants used inconsistently).

---

## Recommended Architecture: Hybrid Decomposed + RDF

The key insight is that BIBFRAME is a **graph model** but your use cases (search, browse, API responses) need **relational structure**. The solution is to decompose the graph into relational tables while preserving the ability to reconstruct the full RDF graph.

```
┌─────────────────────────────────────────────────────────┐
│                  EXPORT / SERIALIZATION                  │
│           (Reconstruct RDF from relational data)         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────────┐    ┌────────────────────────────┐  │
│  │ Core Entity      │    │ Relationship Tables        │  │
│  │ Tables           │───▶│ (the graph structure)      │  │
│  │ (Work, Expr,     │    │                            │  │
│  │  Manif, Item)    │    │ Work──Agent (contribution) │  │
│  └─────────────────┘    │ Work──Subject              │  │
│                         │ Work──Expression           │  │
│  ┌─────────────────┐    │ Expression──Manifestation  │  │
│  │ Shared Entity    │    │ Manifestation──Item        │  │
│  │ Tables           │───▶│ Manifestation──Series      │  │
│  │ (Agent, Subject, │    │ etc.                       │  │
│  │  Identifier)     │    └────────────────────────────┘  │
│  └─────────────────┘                                    │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                    ELASTICSEARCH                        │
│  Denormalized, flattened documents for discovery        │
└─────────────────────────────────────────────────────────┘
```

---

## Core Entity Tables

### Works

```sql
CREATE TABLE bibframe_works (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    biblio_id    BIGINT UNSIGNED NOT NULL,
    uri             VARCHAR(512) NOT NULL,
    title           VARCHAR(1024),
    title_normalized VARCHAR(1024),  -- for dedup/fuzzy matching
    work_type       VARCHAR(128),    -- e.g. 'MonographWork', 'SerialWork'
    language        VARCHAR(32),
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (biblio_id),
    KEY (title_normalized(191))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Expressions

```sql
CREATE TABLE bibframe_expressions (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    work_id         BIGINT UNSIGNED NOT NULL,
    uri             VARCHAR(512) NOT NULL,
    expression_type VARCHAR(128),    -- 'Text', 'NotatedMusic', etc.
    language        VARCHAR(32),     -- expression language (MARC 041)
    edition_statement VARCHAR(255),
    content_type    VARCHAR(128),    -- MARC 336
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (work_id),
    CONSTRAINT fk_expr_work FOREIGN KEY (work_id) REFERENCES bibframe_works(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Manifestations

```sql
CREATE TABLE bibframe_manifestations (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    expression_id       BIGINT UNSIGNED NOT NULL,
    biblio_id        BIGINT UNSIGNED,  -- direct link to Koha biblio
    uri                 VARCHAR(512) NOT NULL,
    manifestation_type  VARCHAR(128),     -- 'Print', 'Electronic', 'Microform'
    publisher_name      VARCHAR(512),
    publication_place   VARCHAR(255),
    publication_date    VARCHAR(128),     -- MARC 264 $c (free text)
    publication_date_sort DATE,           -- normalized for sorting
    extent              VARCHAR(512),     -- MARC 300
    media_type          VARCHAR(128),     -- MARC 337
    carrier_type        VARCHAR(128),     -- MARC 338
    series              VARCHAR(512),
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (expression_id),
    KEY (biblio_id),
    KEY (publication_date_sort),
    KEY (publisher_name(191)),
    CONSTRAINT fk_manif_expr FOREIGN KEY (expression_id) REFERENCES bibframe_expressions(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Items

```sql
CREATE TABLE bibframe_items (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    manifestation_id    BIGINT UNSIGNED NOT NULL,
    uri                 VARCHAR(512) NOT NULL,
    item_type           VARCHAR(128),
    shelf_mark          VARCHAR(255),
    sublocation         VARCHAR(255),
    enumeration         VARCHAR(255),
    chronology          VARCHAR(255),
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (manifestation_id),
    CONSTRAINT fk_item_manif FOREIGN KEY (manifestation_id) REFERENCES bibframe_manifestations(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Shared Authority Tables

These are the critical linked data entities — **agents and subjects must be separate tables** because they are reused across many works. This is the biggest win over the current blob approach.

### Agents

```sql
CREATE TABLE bibframe_agents (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uri         VARCHAR(512) NOT NULL,
    agent_type  ENUM('Person','Family','Organization','Meeting','Jurisdiction') NOT NULL,
    name        VARCHAR(1024) NOT NULL,
    name_normalized VARCHAR(1024),  -- for dedup (NACO normalization)
    variant_names JSON,              -- array of variant name forms
    identifiers JSON,                -- {"isni":"0000...","viaf":"1234",...}
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (name(191)),
    KEY (name_normalized(191)),
    KEY (agent_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Subjects

```sql
CREATE TABLE bibframe_subjects (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uri             VARCHAR(512) NOT NULL,
    subject_type    ENUM('Topic','GenreForm','Geographic','Temporal') NOT NULL,
    term            VARCHAR(1024) NOT NULL,
    term_normalized VARCHAR(1024),
    source          VARCHAR(128),    -- 'lcsh','bisac','ykl', etc.
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (term(191)),
    KEY (term_normalized(191)),
    KEY (source)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Identifiers

```sql
-- Identifiers appear on any entity; polymorphic table avoids 5+ separate tables
CREATE TABLE bibframe_identifiers (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    entity_type     ENUM('work','expression','manifestation','item','agent') NOT NULL,
    entity_id       BIGINT UNSIGNED NOT NULL,
    identifier_type VARCHAR(64) NOT NULL,  -- 'isbn','issn','lccn','doi','isni',etc.
    value           VARCHAR(512) NOT NULL,
    value_normalized VARCHAR(512),          -- for dedup (strip hyphens etc.)
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    KEY (entity_type, entity_id),
    KEY (identifier_type),
    KEY (value_normalized(191)),
    UNIQUE KEY (entity_type, entity_id, identifier_type, value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Relationship Tables

This is where the **graph structure** lives. These tables replace the RDF triples that currently connect entities.

### Work ↔ Agent (creators, contributors)

```sql
CREATE TABLE bibframe_contributions (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    work_id     BIGINT UNSIGNED NOT NULL,
    agent_id    BIGINT UNSIGNED NOT NULL,
    role        VARCHAR(128),          -- relator code (aut, edr, etc.)
    role_uri    VARCHAR(512),          -- full URI of role
    sequence    SMALLINT UNSIGNED,     -- order of appearance
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    KEY (work_id),
    KEY (agent_id),
    KEY (role),
    UNIQUE KEY (work_id, agent_id, role),
    CONSTRAINT fk_contrib_work FOREIGN KEY (work_id) REFERENCES bibframe_works(id),
    CONSTRAINT fk_contrib_agent FOREIGN KEY (agent_id) REFERENCES bibframe_agents(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Work ↔ Subject

```sql
CREATE TABLE bibframe_work_subjects (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    work_id     BIGINT UNSIGNED NOT NULL,
    subject_id  BIGINT UNSIGNED NOT NULL,
    sequence    SMALLINT UNSIGNED,
    UNIQUE KEY (work_id, subject_id),
    CONSTRAINT fk_ws_work FOREIGN KEY (work_id) REFERENCES bibframe_works(id),
    CONSTRAINT fk_ws_subject FOREIGN KEY (subject_id) REFERENCES bibframe_subjects(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Expression ↔ Subject

```sql
CREATE TABLE bibframe_expression_subjects (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    expression_id BIGINT UNSIGNED NOT NULL,
    subject_id    BIGINT UNSIGNED NOT NULL,
    sequence      SMALLINT UNSIGNED,
    UNIQUE KEY (expression_id, subject_id),
    CONSTRAINT fk_es_expr FOREIGN KEY (expression_id) REFERENCES bibframe_expressions(id),
    CONSTRAINT fk_es_subject FOREIGN KEY (subject_id) REFERENCES bibframe_subjects(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Manifestation → Series

```sql
CREATE TABLE bibframe_series (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uri             VARCHAR(512) NOT NULL,
    title           VARCHAR(1024) NOT NULL,
    issn            VARCHAR(32),
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY (uri),
    KEY (title(191))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE bibframe_manifestation_series (
    manifestation_id BIGINT UNSIGNED NOT NULL,
    series_id        BIGINT UNSIGNED NOT NULL,
    numbering        VARCHAR(255),
    sequence         SMALLINT UNSIGNED,
    UNIQUE KEY (manifestation_id, series_id),
    CONSTRAINT fk_ms_manif FOREIGN KEY (manifestation_id) REFERENCES bibframe_manifestations(id),
    CONSTRAINT fk_ms_series FOREIGN KEY (series_id) REFERENCES bibframe_series(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Electronic Locators (MARC 856)

```sql
CREATE TABLE bibframe_electronic_locators (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    manifestation_id    BIGINT UNSIGNED NOT NULL,
    url                 VARCHAR(1024) NOT NULL,
    relationship_text   VARCHAR(255),    -- 'resource', 'version of resource', etc.
    public_note         VARCHAR(512),
    link_text           VARCHAR(255),
    CONSTRAINT fk_el_manif FOREIGN KEY (manifestation_id) REFERENCES bibframe_manifestations(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Classifications

```sql
-- Can appear on Work or Expression
CREATE TABLE bibframe_classifications (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    entity_type ENUM('work','expression') NOT NULL,
    entity_id   BIGINT UNSIGNED NOT NULL,
    scheme      VARCHAR(64) NOT NULL,     -- 'lcc','ddc','ykl','udc'
    call_number VARCHAR(128) NOT NULL,
    edition     VARCHAR(64),
    KEY (entity_type, entity_id),
    KEY (scheme),
    KEY (call_number(191))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Notes

```sql
-- Free-text notes; can appear on any entity level
CREATE TABLE bibframe_notes (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    entity_type ENUM('work','expression','manifestation','item') NOT NULL,
    entity_id   BIGINT UNSIGNED NOT NULL,
    note_type   VARCHAR(64),        -- 'general', 'bibliography', 'content', etc.
    value       TEXT NOT NULL,
    language    VARCHAR(32),
    KEY (entity_type, entity_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

## Component Part Linking (MARC21 773/774 ↔ BIBFRAME partOf/hasPart)

Component parts (articles, chapters, issues) link to host records (journals, books, serials) via MARC21 773/774 and BIBFRAME `partOf`/`hasPart`. This is one of the most common query patterns in library catalogs.

### How Component Parts Map Between Formats

| MARC21 Tag | Description | BIBFRAME Property | BFFI Property | Direction |
|------------|-------------|-------------------|---------------|-----------|
| 773 | Host Item Entry | `bf:partOf` | `bffi:partOf` | Component → Host |
| 774 | Constituent Unit Entry | `bf:hasPart` | `bffi:hasPart` | Host → Component |
| 770 | Supplement | `bf:supplement` | — | Supplement → Host |
| 772 | Supplement Parent | `bf:supplementTo` | — | Host → Supplement |
| 780 | Preceding Entry | `bf:precededBy` | — | Successor → Predecessor |
| 785 | Succeeding Entry | `bf:succeededBy` | — | Predecessor → Successor |

### Component Parts Table

```sql
CREATE TABLE bibframe_component_parts (
    id                      BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    host_work_id            BIGINT UNSIGNED,     -- FK to bibframe_works.id (nullable if host not local)
    host_manifestation_id   BIGINT UNSIGNED,     -- FK to bibframe_manifestations.id (nullable)
    component_work_id       BIGINT UNSIGNED NOT NULL, -- FK to bibframe_works.id
    component_manifestation_id BIGINT UNSIGNED,  -- FK to bibframe_manifestations.id

    relationship_type       ENUM(
        'partOf','hasPart','supplement','supplementTo',
        'precededBy','succeededBy','hasReproduction','relatedTo'
    ) NOT NULL,

    relationship_label      VARCHAR(512),        -- from $i (display text)
    relationship_info       VARCHAR(512),        -- from $g (relationship information)
    volume_designation      VARCHAR(255),        -- from $v
    note                    TEXT,                -- from $n

    -- When the host record doesn't exist locally
    host_title              VARCHAR(1024),       -- from $t
    host_issn               VARCHAR(32),         -- from $x
    host_control_number     VARCHAR(128),        -- from $w (OCoLC etc.)
    host_uri                VARCHAR(512),        -- from $0 or constructed

    -- Provenance for MARC21 round-trip
    source_marc_tag         VARCHAR(4),
    source_marc_subfields   JSON,

    created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    KEY (host_work_id),
    KEY (component_work_id),
    KEY (host_issn),
    KEY (relationship_type),

    CONSTRAINT fk_cp_host_work FOREIGN KEY (host_work_id) REFERENCES bibframe_works(id) ON DELETE SET NULL,
    CONSTRAINT fk_cp_host_manif FOREIGN KEY (host_manifestation_id) REFERENCES bibframe_manifestations(id) ON DELETE SET NULL,
    CONSTRAINT fk_cp_comp_work FOREIGN KEY (component_work_id) REFERENCES bibframe_works(id) ON DELETE CASCADE,
    CONSTRAINT fk_cp_comp_manif FOREIGN KEY (component_manifestation_id) REFERENCES bibframe_manifestations(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Querying Component Parts

```sql
-- "Find all articles in Journal X"
SELECT w.id, w.title, w.uri
FROM bibframe_component_parts cp
JOIN bibframe_works w ON cp.component_work_id = w.id
JOIN bibframe_works host ON cp.host_work_id = host.id
WHERE host.title LIKE '%Journal of Tolkien research%'
  AND cp.relationship_type = 'partOf';

-- "Find the host of this article"
SELECT host.id, host.title, host.uri
FROM bibframe_component_parts cp
JOIN bibframe_works host ON cp.host_work_id = host.id
WHERE cp.component_work_id = 42
  AND cp.relationship_type = 'partOf';

-- "Find all issues of a serial (by ISSN)"
SELECT w.id, w.title, w.uri, cp.volume_designation
FROM bibframe_component_parts cp
JOIN bibframe_works w ON cp.component_work_id = w.id
WHERE cp.host_issn = '2373-2043'
  AND cp.relationship_type = 'partOf'
ORDER BY cp.volume_designation;

-- "Find components when host is NOT in local catalog"
SELECT cp.component_work_id, w.title, cp.host_title, cp.host_issn
FROM bibframe_component_parts cp
JOIN bibframe_works w ON cp.component_work_id = w.id
WHERE cp.host_work_id IS NULL
  AND cp.host_issn IS NOT NULL;
```

### Resolution: When the Host Doesn't Exist Locally

```
Component Record (local)          Host Record (NOT local)
┌──────────────────────┐         ┌─────────────────────────┐
│ bibframe_works       │         │ bibframe_component_parts │
│ id: 12345            │◄────────│ component_work_id: 12345│
│ title: "Article..."  │         │ host_work_id: NULL      │
│ biblio_id: 12345     │         │ host_title: "Journal..."│
└──────────────────────┘         │ host_issn: "2373-2043"  │
                                 │ host_control_number: ... │
                                 │ relationship_type: partOf│
                                 └─────────────────────────┘
```

The typed columns (`host_title`, `host_issn`, `volume_designation`) handle the case where the host is not in the local catalog. When the host record is later added, the `host_work_id` FK can be populated.

For full analysis of component part linking strategies, see `ANALYSIS_COMPONENT_PARTS.md`.

---

## Elasticsearch Index Design

Each ES document represents a discoverable resource — flattened, denormalized, optimized for search.

### Index: bibframe_works

```json
{
  "id": 123,
  "biblio_id": 456,
  "uri": "http://urn.fi/URN:NBN:fi:bib:work/123",
  "title": "Suomen historiallinen bibliografia",
  "title_normalized": "suomen historiallinen bibliografia",
  "work_type": "MonographWork",
  "languages": ["fin", "swe"],
  "creators": [
    { "name": "Hakulinen, Veli", "role": "aut", "agent_id": 789 }
  ],
  "subjects": [
    { "term": "Suomi -- historia", "type": "Topic", "source": "lcsh" },
    { "term": "Finland", "type": "Geographic" }
  ],
  "classifications": [
    { "scheme": "ykl", "call_number": "947.1" }
  ],
  "identifiers": [
    { "type": "isbn", "value": "978-952-123456-7" }
  ],
  "manifestation_count": 3,
  "has_electronic": true,
  "publication_date_sort": "2024-01-01",
  "suggest": {
    "input": ["suomen historiallinen bibliografia", "hakulinen", "veli"],
    "weight": 10
  }
}
```

### Index: bibframe_agents

```json
{
  "id": 789,
  "uri": "http://urn.fi/URN:NBN:fi:bib:agent/hakulinen_veli",
  "agent_type": "Person",
  "name": "Hakulinen, Veli",
  "name_normalized": "hakulinen veli",
  "identifiers": { "isni": "0000000123456789", "viaf": "12345" },
  "work_count": 42,
  "suggest": {
    "input": ["hakulinen", "veli", "hakulinen veli"],
    "weight": 10
  }
}
```

---

## Data Linking Architecture

The linking architecture has three tiers.

### Tier 1: MariaDB Foreign Keys (structural links)

```
Work ──FK──▶ Expression ──FK──▶ Manifestation ──FK──▶ Item

Work ──FK──▶ bibframe_contributions ──FK──▶ Agent
Work ──FK──▶ bibframe_work_subjects ──FK──▶ Subject
Manifestation ──FK──▶ bibframe_manifestation_series ──FK──▶ Series
```

These are **hard links** with referential integrity. Deleting a Work cascades to its Expression, which cascades to its Manifestation, etc.

### Tier 2: Shared Entity Tables (deduplication links)

- `bibframe_agents` **deduplicates agents** — one row per real-world person/org, linked from many works via `bibframe_contributions`
- `bibframe_subjects` **deduplicates subjects** — one row per topic, linked from many works
- `bibframe_identifiers` **links identifiers** to any entity polymorphically (`entity_type` + `entity_id`)

### Tier 3: Elasticsearch (search/discovery links)

- Each ES document contains **denormalized copies** of related entity data (creator names, subject terms)
- ES `join` field type can model parent-child (work → expression → manifestation) for filtered queries
- Cross-references via entity IDs allow joining back to MariaDB for full detail

---

## Key Design Decisions

| Decision | Recommendation | Reasoning |
|----------|---------------|-----------|
| **Storage of serialized RDF** | Keep in `biblio_metadata` | Preserves round-trip fidelity for export/interop |
| **URI generation** | Store URI as `VARCHAR(512)` with UNIQUE index | URIs are the primary link key in RDF; must be unique |
| **Agent deduplication** | Normalize names (NACO rules) in `name_normalized` | Enables fuzzy matching and dedup before insert |
| **Identifier storage** | Polymorphic table (`entity_type` + `entity_id`) | Identifiers appear on any entity; avoids 5+ tables |
| **Full-text on notes** | MariaDB FULLTEXT index on `value` | Allows local text search without ES for simple cases |
| **ES sync strategy** | Event-driven (trigger on MariaDB insert/update) | Ensures near-real-time search index |
| **Multi-valued properties** | Separate rows in dedicated tables | MariaDB doesn't support multi-valued columns natively |

---

## Why This Is Better Than Current Approach

1. **Searchable** — "Find all Works by author X" becomes a simple JOIN query, not parsing Turtle
2. **Deduplicated** — One Person entity, linked from many Works, not copy-pasted in every record
3. **Elasticsearch-ready** — Flat documents derived from relational tables are trivial to index
4. **Queryable by any element** — Subjects, identifiers, classifications, dates — all become indexed columns
5. **Preserves RDF fidelity** — The serialized RDF in `biblio_metadata` is kept for export; the decomposed tables are the read-optimized view
6. **Maintains Koha compatibility** — `biblio_id` FKs keep everything linked to Koha's catalog

---

## Migration Path

The recommended implementation order:

| Phase | What | Description |
|-------|------|-------------|
| 1 | Create new tables | Add DDL to `install()`/`upgrade()` in the plugin |
| 2 | Build conversion function | Parse existing `biblio_metadata` RDF blobs and populate the new tables |
| 3 | Add ES sync | MariaDB → Elasticsearch sync mechanism |
| 4 | Update API layer | Query the new tables instead of raw SQL against `biblio_metadata` |
| 5 | Batch re-index cronjob | New cronjob that re-indexes all records into the decomposed schema |

---

## Comparison: Current vs Proposed

| Aspect | Current (Blob Storage) | Proposed (Decomposed + RDF) |
|--------|----------------------|----------------------------|
| **Query: "All Works by author X"** | Parse every Turtle blob | `SELECT w.* FROM bibframe_works w JOIN bibframe_contributions c ON w.id = c.work_id JOIN bibframe_agents a ON c.agent_id = a.id WHERE a.name LIKE '%Hakulinen%'` |
| **Deduplication** | None — same agent in every record | One agent row, linked from many works |
| **Search** | Not possible without parsing | ES index with suggest, full-text, facets |
| **Export to MARC21** | Not possible (only RDF formats) | Decomposed data → MARC21 generator |
| **Export to BIBFRAME** | Already works (but from blobs) | Decomposed data → RDF generator |
| **Referential integrity** | None (URI strings) | Foreign keys with CASCADE |
| **Performance** | Must load entire blob to answer any question | Indexed column queries |
