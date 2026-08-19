# Format-Agnostic BIBFRAME Data Model Analysis

**Date:** 2026-08-17
**Status:** Analysis / Design Document
**Author:** Johanna Räisä (assisted by opencode/big-pickle LLM)

---

## Table of Contents

1. [Current State](#current-state)
2. [Key Insight](#key-insight)
3. [EAV Pattern Explained](#eav-pattern-explained)
4. [Three-Layer Architecture](#three-layer-architecture)
5. [MariaDB Schema Design](#mariadb-schema-design)
6. [Elasticsearch Integration](#elasticsearch-integration)
7. [Format Export Generators](#format-export-generators)
8. [Data Flow](#data-flow)
9. [Deduplication Strategy](#deduplication-strategy)
10. [Component Part Linking](#component-part-linking-marc21-773774--bibframe-partofhaspart)
11. [Implementation Phases](#implementation-phases)
12. [Key Design Principles](#key-design-principles)

---

## EAV Pattern Explained

**EAV = Entity-Attribute-Value** (also called the "open schema" or "key-value" pattern).

### Traditional Column Approach

Each property gets its own column in the table:

```sql
CREATE TABLE books (
    id          INT PRIMARY KEY,
    title       VARCHAR(255),
    author_name VARCHAR(255),
    pub_date    DATE
);

INSERT INTO books VALUES (1, 'Suomen historia', 'Hakulinen, Veli', '2024-01-15');

-- Query: simple
SELECT * FROM books WHERE pub_date > '2023-12-31';
```

### EAV Approach

All properties are stored as rows in a generic table:

```sql
CREATE TABLE book_properties (
    entity_id   INT,
    attribute   VARCHAR(64),
    value       TEXT
);

INSERT INTO book_properties VALUES
    (1, 'title',       'Suomen historia'),
    (1, 'author_name', 'Hakulinen, Veli'),
    (1, 'pub_date',    '2024-01-15');

-- Query: complex (must scan the attribute column)
SELECT * FROM book_properties
WHERE attribute = 'pub_date' AND value > '2023-12-31';
```

### The Trade-off

| Aspect | Traditional Columns | EAV Pattern |
|--------|-------------------|-------------|
| **Adding new property** | `ALTER TABLE` + code change | New row, no schema change |
| **Query speed** | Fast (direct index on column) | Slower (scan + filter on attribute key) |
| **Query simplicity** | `WHERE pub_date > '2023'` | `WHERE attribute = 'pub_date' AND value > '2023'` |
| **Schema flexibility** | Rigid (columns are fixed) | Flexible (any property can be added) |
| **Storage efficiency** | Compact (one row per entity) | Verbose (multiple rows per entity) |
| **Type safety** | Enforced by column type | All values are TEXT (no type checking) |
| **Reporting** | Simple GROUP BY on columns | Requires pivoting the EAV table |

### Why Plan B Uses EAV

Plan B's `record_properties` table is an EAV pattern where:

- **Entity** = `resource_id` (FK to `record_resources`)
- **Attribute** = `property_key` (e.g. `'mainTitle'`, `'language'`, `'publication_date'`)
- **Value** = `value_text` (the actual value)

This allows the same storage to handle MARC21, BIBFRAME, Dublin Core, or any future format without changing the schema. The cost is more complex queries and no type safety on individual properties.

### When EAV Works Well

- Properties vary widely between records (some have ISBN, some have DOI, some have neither)
- New property types are added frequently
- Format-agnostic storage is a priority
- Read performance is less critical than write flexibility

### When EAV Hurts

- Common queries need to filter on specific properties (e.g. "all books published in 2024")
- Reporting and analytics require pivot operations
- Type safety is important (dates, numbers should not be stored as TEXT)

### Plan A vs Plan B: The Core Difference

Plan A avoids EAV for the most common properties by using **typed columns** on each entity table (e.g. `bibframe_manifestations.publication_date`). Plan B accepts EAV overhead for the benefit of format flexibility. The hybrid option is to use Plan B's generic storage but add **specialized summary tables** for the most common query patterns.

---

## Current State

The plugin stores everything as serialized RDF blobs in Koha's `biblio_metadata` table. This means:

- **No queryable structure** — you can't efficiently search for "all Works by author X" or "all Manifestations in format Y"
- **No entity deduplication** — the same Person agent is duplicated across every Work they contributed to
- **No Elasticsearch integration** — nothing is indexed for search
- **No referential integrity** — links between entities are URI strings, not enforced foreign keys
- **No format-agnostic export** — data is locked into whichever RDF serialization was chosen at save time

---

## Key Insight

**MARC21 and BIBFRAME describe the same real-world entities.** A book is a book regardless of encoding. The difference is structural: MARC21 flattens everything into a single record with tags/subfields, while BIBFRAME decomposes it into a graph of linked entities. The format-agnostic approach stores **semantic facts** rather than format-specific encodings.

This is exactly what FOLIO calls being "format agnostic" — their Inventory module is "not dependent on any specific source or format of bibliographic data." Share-VDE uses BIBFRAME as the canonical internal model and converts to/from MARC at the edges.

### What's Actually Format-Agnostic vs Format-Specific?

| Concept | Semantic Fact (format-agnostic) | MARC21 Encoding | BIBFRAME Encoding |
|---------|--------------------------------|-----------------|-------------------|
| Author | "Entity X created Resource Y" | 100 $a name | bf:contribution → bf:Agent |
| Title | "Resource Y is titled 'Z'" | 245 $a title | bf:title → bf:Title → bf:mainTitle |
| Subject | "Resource Y is about Topic T" | 650 $a term | bf:subject → bf:Topic |
| Publication | "Published in Place P, Date D" | 260/264 $a$b$c | bf:provisionActivity → bf:Publication |
| Identifier | "Has identifier I of type T" | 020/022/024 | bf:identifiedBy → bf:Isbn/bf:Issn |
| Language | "Expression is in Language L" | 041/040 $b | bf:language → bf:Language |
| Classification | "Classified as C in scheme S" | 050/080/084 | bf:classification → bf:ClassificationLcc |

The **semantic fact is identical**. Only the serialization differs.

---

## Three-Layer Architecture

```
┌─────────────────────────────────────────────────────┐
│              EXPORT LAYER (Format Generators)       │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ MARC21   │  │ BIBFRAME │  │ JSON-LD / Other  │  │
│  │ Generator│  │ Generator│  │ Generators       │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────────────┘  │
│       │              │              │                │
├───────┴──────────────┴──────────────┴────────────────┤
│              STORAGE LAYER (Semantic Primitives)     │
│                                                     │
│  Resources ──── Properties ──── Links               │
│  (resources,    (title, date,   (who did what       │
│   agents,        note, lang,     to what)           │
│   subjects)      identifier,                        │
│                  classification)                    │
│                                                     │
├─────────────────────────────────────────────────────┤
│              SEARCH LAYER (Elasticsearch)            │
│  Denormalized, flattened documents for discovery    │
└─────────────────────────────────────────────────────┘
```

---

## MariaDB Schema Design

### Core Entity Table (format-agnostic)

```sql
-- ============================================================
-- A "resource" is anything that can be described.
-- This is deliberately NOT named "work" or "instance" —
-- it's format-agnostic. The resource_type tells you the
-- BIBFRAME level, but the table works for any model.
-- ============================================================
CREATE TABLE record_resources (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uri             VARCHAR(512) NOT NULL,
    resource_type   ENUM(
        'Work','Expression','Manifestation','Item',
        'Instance',
        'Agent','Person','Organization','Meeting','Family',
        'Topic','GenreForm','Geographic','Temporal',
        'Title','ProvisionActivity','Publication',
        'Place','Language','Content','Media','Carrier',
        'Identifier','Classification','Note',
        'Series','AdminMetadata'
    ) NOT NULL,
    biblio_id    BIGINT UNSIGNED,  -- link to Koha (nullable for shared entities)

    -- Denormalized "quick access" fields for the most common queries.
    -- These are derived from properties but stored here for performance.
    label           VARCHAR(1024),    -- human-readable label (name, title, term)
    label_normalized VARCHAR(1024),   -- NACO-normalized for dedup

    -- Provenance
    source_format   ENUM('marc21','bibframe','bffi','manual','imported') DEFAULT 'manual',
    source_record   BIGINT UNSIGNED,  -- original biblio if imported from MARC
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (uri),
    KEY (resource_type),
    KEY (biblio_id),
    KEY (label_normalized(191)),
    KEY (source_format)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Properties Table (format-agnostic key-value pairs)

```sql
-- ============================================================
-- Properties are format-agnostic key-value pairs on any resource.
-- The property_uri uses vocabularies (bf:, bffi:, rdaw:, etc.)
-- but the data itself is format-independent.
-- ============================================================
CREATE TABLE record_properties (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    property_uri    VARCHAR(512) NOT NULL,   -- e.g. 'http://id.loc.gov/ontologies/bibframe/mainTitle'
    property_key    VARCHAR(128) NOT NULL,   -- shorthand: 'mainTitle', 'language', etc.

    -- The value can be a literal or a reference to another resource
    value_type      ENUM('literal','resource','bnode') NOT NULL,

    -- For literal values:
    value_text      TEXT,                    -- the actual text value
    value_normalized TEXT,                   -- for searching/sorting
    value_datatype  VARCHAR(256),            -- xsd:dateTime, xsd:integer, etc.
    value_lang      VARCHAR(32),             -- language tag (fin, eng, etc.)

    -- For resource references:
    value_resource_id BIGINT UNSIGNED,       -- FK to record_resources.id

    -- For ordering multi-valued properties:
    sequence        SMALLINT UNSIGNED DEFAULT 0,

    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    KEY (resource_id),
    KEY (property_key),
    KEY (property_uri(191)),
    KEY (value_text(191)),
    KEY (value_resource_id),
    CONSTRAINT fk_prop_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id)
        ON DELETE CASCADE,
    CONSTRAINT fk_prop_value_res FOREIGN KEY (value_resource_id) REFERENCES record_resources(id)
        ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Links Table (structural relationships / the graph)

```sql
-- ============================================================
-- Explicit relationships between resources.
-- This replaces RDF triples like: Work --hasExpression--> Expression
-- These are the structural relationships that make the graph.
-- ============================================================
CREATE TABLE record_links (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    source_resource_id  BIGINT UNSIGNED NOT NULL,
    target_resource_id  BIGINT UNSIGNED NOT NULL,
    relationship_type   VARCHAR(128) NOT NULL,  -- 'hasExpression','contribution','subject', etc.
    relationship_uri    VARCHAR(512),            -- full URI if needed
    sequence            SMALLINT UNSIGNED DEFAULT 0,

    -- For relationship properties (e.g. role in a contribution)
    properties_json     JSON,                    -- additional props on the link itself

    UNIQUE KEY (source_resource_id, target_resource_id, relationship_type),
    KEY (target_resource_id),
    KEY (relationship_type),
    CONSTRAINT fk_link_source FOREIGN KEY (source_resource_id) REFERENCES record_resources(id)
        ON DELETE CASCADE,
    CONSTRAINT fk_link_target FOREIGN KEY (target_resource_id) REFERENCES record_resources(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Format Mappings Table (track per-format representations)

```sql
-- ============================================================
-- Tracks how a resource maps to specific formats.
-- This is the key to format-agnosticism — the same resource
-- can have both a MARC21 representation and a BIBFRAME one.
-- ============================================================
CREATE TABLE record_format_mappings (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_id     BIGINT UNSIGNED NOT NULL,
    format_name     ENUM('marc21','bffi','bibframe2','bibframe3') NOT NULL,

    -- For MARC21: the biblio_id + original MARC tags
    -- For BIBFRAME: the serialized RDF
    serialized_data MEDIUMBLOB,              -- full serialized record in this format

    -- For MARC21 mapping: which MARC tags contribute to this resource
    marc_tags_json  JSON,                    -- ["100","245","650",...]

    -- Version tracking
    version         INT UNSIGNED DEFAULT 1,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY (resource_id, format_name),
    CONSTRAINT fk_fmt_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Graphs Table (groups resources into coherent descriptions)

```sql
-- ============================================================
-- A "graph" represents a complete bibliographic description
-- (Work + Expression + Manifestation + Item chain).
-- ============================================================
CREATE TABLE record_graphs (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    biblio_id    BIGINT UNSIGNED NOT NULL,
    graph_type      VARCHAR(64) DEFAULT 'bibliographic',  -- 'bibliographic', 'authority', 'subject'
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

The ES index is a **derived view** of the semantic store, not the source of truth.

### Index: record_entities (one document per biblio_id)

```json
{
  "biblio_id": 42,
  "work": {
    "uri": "http://urn.fi/URN:NBN:fi:bib:work/42",
    "label": "Suomen historiallinen bibliografia",
    "type": "Work",
    "language": ["fin", "swe"],
    "subjects": [
      {"term": "Suomi -- historia", "type": "Topic", "source": "lcsh"},
      {"term": "Finland", "type": "Geographic"}
    ],
    "classifications": [
      {"scheme": "ykl", "call_number": "947.1"}
    ]
  },
  "agents": [
    {"name": "Hakulinen, Veli", "role": "aut", "agent_id": 789, "isni": "0000..."}
  ],
  "manifestation": {
    "publisher": "Suomalaisen Kirjallisuuden Seura",
    "date": "2024",
    "date_sort": "2024-01-01",
    "formats": ["print", "electronic"],
    "identifiers": [
      {"type": "isbn", "value": "978-952-123456-7"}
    ]
  },
  "suggest": {
    "input": ["suomen historiallinen bibliografia", "hakulinen", "veli"],
    "weight": 10
  }
}
```

### Index: record_agents (authority-style browsing)

```json
{
  "id": 789,
  "name": "Hakulinen, Veli",
  "name_normalized": "hakulinen veli",
  "agent_type": "Person",
  "work_count": 42,
  "identifiers": {"isni": "0000000123456789"},
  "suggest": {
    "input": ["hakulinen", "veli", "hakulinen veli"],
    "weight": 10
  }
}
```

---

## Format Export Generators

### MARC21 Export (semantic store → MARC21 XML)

Uses a mapping YAML that translates semantic properties to MARC21 tags/subfields:

```yaml
# marc_mapping.yaml — Format-specific mapping from semantic properties to MARC21
marc21_export:
  mainTitle:
    tag: '245'
    subfield: 'a'
  subtitle:
    tag: '245'
    subfield: 'b'
  language:
    tag: '008'
    positions: '35-37'
  contribution:
    tag_pattern: '100|110|111|700|710|711'
    subfields:
      a: 'name'
      e: 'role_term'
      '0': 'uri'
  subject:
    tag_pattern: '600|610|611|630|650|651'
    subfields:
      a: 'term'
      '2': 'source'
  isbn:
    tag: '020'
    subfield: 'a'
  issn:
    tag: '022'
    subfield: 'a'
  publication_place:
    tag: '264'
    subfield: 'a'
  publisher_name:
    tag: '264'
    subfield: 'b'
  publication_date:
    tag: '264'
    subfield: 'c'
```

### BIBFRAME Export (semantic store → RDF triples)

Uses the existing `bibframe_mapping.yaml` in reverse:

- `resource.uri` + `rdf:type` + `resource.resource_type`
- `resource.uri` + `bf:mainTitle` + `property.value_text`
- `resource.uri` + `bf:contribution` + `agent.uri`

---

## Component Part Linking (MARC21 773/774 ↔ BIBFRAME partOf/hasPart)

One of the most critical relationships in library catalogs: linking component parts (articles, chapters, issues) to their host records (journals, books, serials). The challenge is that **the host record often does not exist locally**.

### How Component Parts Map Between Formats

| MARC21 Tag | Description | BIBFRAME Property | BFFI Property | Direction |
|------------|-------------|-------------------|---------------|-----------|
| 773 | Host Item Entry | `bf:partOf` | `bffi:partOf` | Component → Host |
| 774 | Constituent Unit Entry | `bf:hasPart` | `bffi:hasPart` | Host → Component |
| 770 | Supplement | `bf:supplement` | — | Supplement → Host |
| 772 | Supplement Parent | `bf:supplementTo` | — | Host → Supplement |
| 775 | Other Edition | `bf:otherEdition` | — | Edition ↔ Edition |
| 776 | Additional Physical Form | `bf:hasReproduction` | — | Original → Reproduction |
| 780 | Preceding Entry | `bf:precededBy` | — | Successor → Predecessor |
| 785 | Succeeding Entry | `bf:succeededBy` | — | Predecessor → Successor |
| 787 | Nonspecific Related | `bf:relatedTo` | — | Any ↔ Any |

### Storage in Plan B: Two Approaches

**Approach 1: Stub Resources (Recommended)**

When the host record doesn't exist locally, create a lightweight "stub" resource:

```sql
-- Component Work (local record)
INSERT INTO record_resources (uri, resource_type, biblio_id, label, source_format)
VALUES ('http://urn.fi/URN:NBN:fi:bib:work/12345', 'Work', 12345, 'Article about Tolkien', 'marc21');

-- Host Work (stub — not in local catalog)
INSERT INTO record_resources (uri, resource_type, label, source_format)
VALUES ('urn:local:host:issn:2373-2043', 'Work', 'Journal of Tolkien research', 'stub');

-- Link component to host
INSERT INTO record_links (source_resource_id, target_resource_id, relationship_type, properties_json)
VALUES (
    12345,    -- component resource id
    <stub_id>,-- host stub resource id
    'partOf',
    '{"label": "article in", "volume": "vol. 5, no. 2", "marc_tag": "773", "marc_subfields": {"t": "Journal of Tolkien research", "x": "2373-2043", "v": "vol. 5, no. 2", "g": "article in"}}'
);
```

**Approach 2: Properties on the Component (Fallback)**

```sql
-- Store host reference data as properties on the component
INSERT INTO record_properties (resource_id, property_uri, property_key, value_type, value_text)
VALUES
    (12345, 'http://id.loc.gov/ontologies/bibframe/partOf', 'hostTitle', 'literal', 'Journal of Tolkien research'),
    (12345, 'http://id.loc.gov/ontologies/bibframe/partOf', 'hostIssn', 'literal', '2373-2043'),
    (12345, 'http://id.loc.gov/ontologies/bibframe/partOf', 'volumeDesignation', 'literal', 'vol. 5, no. 2'),
    (12345, 'http://id.loc.gov/ontologies/bibframe/partOf', 'relationshipLabel', 'literal', 'article in');
```

### Querying Component Parts

```sql
-- "Find all articles in Journal X" (host exists locally)
SELECT r.id, r.uri, r.label
FROM record_links l
JOIN record_resources target ON l.target_resource_id = target.id
JOIN record_resources r ON l.source_resource_id = r.id
WHERE target.label LIKE '%Journal of Tolkien research%'
  AND l.relationship_type = 'partOf'
  AND r.resource_type = 'Work';

-- "Find all articles in Journal X" (host may NOT exist locally — search stubs/properties)
SELECT r.id, r.uri, r.label
FROM record_resources r
JOIN record_properties p ON r.id = p.resource_id
WHERE p.property_key = 'hostTitle'
  AND p.value_text LIKE '%Journal of Tolkien research%'
  AND r.resource_type = 'Work';

-- "Find the host of this article"
SELECT target.uri, target.label
FROM record_links l
JOIN record_resources target ON l.target_resource_id = target.id
WHERE l.source_resource_id = 12345
  AND l.relationship_type = 'partOf';
```

### Exporting Component Parts

**To MARC21:** Read `record_links` with `relationship_type = 'partOf'`, reconstruct 773 tag from `properties_json` subfields.

**To BIBFRAME:** Read `record_links` with `relationship_type = 'partOf'`, generate `bf:partOf` triples from the link's source → target.

### Design Note: Optional Specialized Table

If component part queries become a performance bottleneck, consider adding a specialized table within Plan B's generic architecture:

```sql
CREATE TABLE record_component_parts (
    id                      BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    component_resource_id   BIGINT UNSIGNED NOT NULL,
    host_resource_id        BIGINT UNSIGNED,    -- nullable if host not local
    relationship_type       VARCHAR(128) NOT NULL,
    relationship_label      VARCHAR(512),
    volume_designation      VARCHAR(255),
    host_title              VARCHAR(1024),
    host_issn               VARCHAR(32),
    host_control_number     VARCHAR(128),
    host_uri                VARCHAR(512),
    source_marc_tag         VARCHAR(4),
    source_marc_subfields   JSON,
    created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    KEY (component_resource_id),
    KEY (host_resource_id),
    KEY (host_issn),
    CONSTRAINT fk_rcp_component FOREIGN KEY (component_resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_rcp_host FOREIGN KEY (host_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

This gives you typed columns for the most common query pattern (serials) while keeping everything else in the generic EAV store. See `ANALYSIS_COMPONENT_PARTS.md` for full analysis.

---

## Data Flow

```
MARC21 Record ──→ MARC Parser ──┐
                                 ├──→ Semantic Normalizer ──→ MariaDB ──┬──→ MARC21 Generator
BIBFRAME RDF ───→ RDF Parser ───┘    (dedup, extract,       Store       └──→ BIBFRAME Generator
                                      link entities)                      └──→ Elasticsearch Sync
```

### Exporting to MARC21 from semantic storage

```sql
-- 1. Get the graph for a biblio_id
SELECT r.id, r.uri, r.resource_type, r.label
FROM record_graphs g
JOIN record_graph_resources gr ON g.id = gr.graph_id
JOIN record_resources r ON gr.resource_id = r.id
WHERE g.biblio_id = 42;

-- 2. Get all properties for the Work resource
SELECT p.property_key, p.value_text, p.value_lang
FROM record_properties p
WHERE p.resource_id = <work_resource_id>;

-- 3. The mapping layer translates:
--    property_key 'mainTitle' → MARC 245 $a
--    property_key 'language'  → MARC 040 $b or 008/35-37
--    relationship 'contribution' → MARC 100/110/700
```

### Exporting to BIBFRAME from semantic storage

```sql
-- Same graph query as above
-- Then build RDF triples directly from the stored properties and links
```

---

## Deduplication Strategy

This is critical for format-agnosticism. The same real-world entity should be stored once.

### Agent Deduplication

```sql
-- Before inserting an agent, check for existing match:
SELECT id FROM record_resources
WHERE resource_type = 'Person'
  AND label_normalized = NACO_normalize('Hakulinen, Veli')
LIMIT 1;

-- If found, reuse the existing resource_id
-- If not, insert new and return the id
```

The `label_normalized` column uses NACO normalization rules (strip punctuation, lowercase, sort particles) to match:

- "Hakulinen, Veli" ≡ "Hakulinen, V. " ≡ "Veli Hakulinen"

### Subject Deduplication

Same approach — normalize the term and source, then match.

### Identifier Deduplication

Identifiers are naturally unique (ISBN, ISSN, DOI, etc.) and can be matched directly.

---

## Implementation Phases

| Phase | What | Files |
|-------|------|-------|
| 1 | Schema DDL | `sql/record_schema.sql` (new) |
| 2 | Install/upgrade hooks | `BibframeManager.pm` `install()` and `upgrade()` |
| 3 | Semantic normalizer | `Modules/SemanticStore.pm` (new) — converts triples/properties to entities |
| 4 | MARC21 → semantic store | Extend `Bibframe.pm` to parse MARC into semantic primitives |
| 5 | BIBFRAME → semantic store | Extend `rdf_to_json()` path to parse RDF into semantic primitives |
| 6 | MARC21 generator | `Modules/MarcGenerator.pm` (new) — semantic store → MARC21 XML |
| 7 | BIBFRAME generator | `Modules/BibframeGenerator.pm` (new) — semantic store → RDF triples |
| 8 | Elasticsearch sync | `Modules/SearchIndex.pm` (new) — MariaDB → ES sync |
| 9 | API updates | `BibframeController.pm` — query semantic store instead of `biblio_metadata` |
| 10 | Batch conversion cronjob | Extend `convert_marc_to_bibframe.pl` |

---

## Key Design Principles

1. **Store semantic facts, not formats** — "Author X created Resource Y" is the truth; whether it's MARC 100 $a or bf:contribution is a serialization choice
2. **One entity, one row** — Agents and subjects are deduplicated; the same Person is not stored twice just because they appear in two Works
3. **Graph is reconstructed on demand** — The `record_links` table provides the graph structure; export generators traverse it
4. **Format mappings are pluggable** — Adding a new output format (Dublin Core, Schema.org, etc.) means adding a new generator, not changing the storage
5. **MARC21 is still first-class** — Koha's core is MARC21; this model preserves full round-trip fidelity (MARC → semantic store → MARC)
6. **Elasticsearch is a derived view** — Never the source of truth; rebuilt from MariaDB on demand
7. **Provenance is tracked** — Every resource knows whether it came from MARC21, BIBFRAME, or manual entry
