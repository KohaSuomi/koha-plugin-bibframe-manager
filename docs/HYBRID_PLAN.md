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
5. [Language and Translation Handling](#language-and-translation-handling)
6. [Work Clustering & Human Review](#work-clustering--human-review)
7. Component Parts Table (Plan A)
8. Format Mappings Table (Plan B)
9. Elasticsearch Integration
10. [Search Integration Strategy](#search-integration-strategy)
11. Data Flow
12. Query Examples
13. Implementation Phases

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

## Where Do Expression Entities Live?

The plan keeps the **LoC BIBFRAME 3-level model (Work → Instance → Item) as the
canonical stored form**. Expressions are **derived, never persisted**:

- A merged cluster is a `record_resources` row of type `Work`, plus its Instances
  tagged with `language` / `languageOfExpression` and `isTranslation` properties.
- The 4-level WEMI Expression level is computed **on demand** — via
  `Bibframe::derive_wemi_from_loc` on BFFI export (Phase 11b) and in the `wemi-4`
  Elasticsearch model (Phase 12). It is never written to `record_resources`
  (even though the `Expression` value exists in the `resource_type` ENUM).
- The RDA relationship "these two translations are expressions of one Work" is
  therefore answered persistently by the **merged Work + its per-Instance
  language/translation properties**, not by stored Expression rows.

This is a deliberate decision: it avoids dual bookkeeping between the derived
Expression level and the canonical 3-level store, at the cost that the Expression
entity itself exists only transiently at export/index time.

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

    -- Original record identification
    original_language  VARCHAR(32),       -- source language of the Work
    original_resource_id BIGINT UNSIGNED NULL,  -- local Expression that is the original; NULL if not local
    original_pending   TINYINT DEFAULT 0, -- 1 = translations linked, original not yet in DB
    original_external_id  VARCHAR(512),   -- external source ref (OCLC/LCCN/URI) when original not local
    original_external_source VARCHAR(128) -- 'oclc','loc','fennica', etc.

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
    KEY (original_language),
    KEY (work_type),
    CONSTRAINT fk_ws_resource FOREIGN KEY (resource_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_ws_orig FOREIGN KEY (original_resource_id) REFERENCES record_resources(id) ON DELETE SET NULL
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

## Language and Translation Handling

### Problem

When converting MARC21 records to BIBFRAME WEMI (Work, Expression, Manifestation, Item), we need to determine:
1. **What language is this expression in?** (MARC 041 $a or 008[35-37])
2. **What is the original language of the work?** (MARC 041 $h if present)
3. **Is this record a translation?** (compare expression language vs original language)

### MARC21 Fields for Language Detection

| Field | Positions/Subfields | Purpose | Example |
|-------|---------------------|---------|---------|
| **008** | 35-37 | Primary language of the record | `fin` for Finnish |
| **041 $a** | Language of text | All languages present in the work | `fin`, `eng` |
| **041 $h** | Original language | Source language (if translated) | `eng` for English original |
| **041 $b** | Intermediate translation | Translation route | `eng` → `swe` → `fin` |
| **041 indicator 1** | Translation flag | `1` = includes/is translation | |

### Detection Algorithm

```perl
sub _detect_original_language {
    my ($self, $marc_record) = @_;
    
    # Priority 1: MARC 041 $h (explicit original language)
    if (my $field_041 = $marc_record->field('041')) {
        if (my $subfield_h = $field_041->subfield('h')) {
            return {
                original_language => $subfield_h,
                is_translation    => 1,
                source           => '041$h',
            };
        }
    }
    
    # Priority 2: MARC 008 positions 35-37 (main language)
    if (my $field_008 = $marc_record->field('008')) {
        my $data = $field_008->data();
        if (length($data) >= 38) {
            my $lang_008 = substr($data, 35, 3);
            $lang_008 =~ s/\s+$//;
            
            # Check if 041 exists with different language → translation
            my $is_translation = 0;
            if (my $field_041 = $marc_record->field('041')) {
                my @subfields_a = $field_041->subfield('a');
                if (@subfields_a && $subfields_a[0] ne $lang_008) {
                    $is_translation = 1;
                }
            }
            
            return {
                original_language => $lang_008,
                is_translation    => $is_translation,
                source           => '008',
            };
        }
    }
    
    # Fallback: no language detected
    return {
        original_language => undef,
        is_translation    => 0,
        source           => 'none',
    };
}
```

### Examples

| MARC Record | 008[35-37] | 041 $a | 041 $h | Detected Original | Is Translation |
|-------------|------------|--------|--------|-------------------|----------------|
| Aleksis Kivi - Seitsemän veljestä | `fin` | `fin` | - | `fin` | No |
| Harry Potter ja viisasten kivi | `fin` | `fin` | `eng` | `eng` | Yes |
| Harry Potter and the Philosopher's Stone | `eng` | `eng` | - | `eng` | No |
| Finnish translation of Swedish book | `fin` | `fin` | `swe` | `swe` | Yes |
| Bilingual Finnish/English text | `fin` | `fin eng` | - | `fin` | No |

### Storage in Core Tables

**record_properties** entries for language:

```sql
-- Expression language (from 041 $a or 008)
INSERT INTO record_properties (resource_id, property_uri, property_key, value_type, value_text, value_lang)
VALUES 
    (expr_id, 'http://urn.fi/URN:NBN:fi:schema:bffi:languageOfExpression', 'languageOfExpression', 'literal', 'fin', 'fi');

-- Original language (from 041 $h)
INSERT INTO record_properties (resource_id, property_uri, property_key, value_type, value_text, value_lang)
VALUES 
    (expr_id, 'http://urn.fi/URN:NBN:fi:schema:bffi:originalLanguage', 'originalLanguage', 'literal', 'eng', 'en');

-- Translation flag
INSERT INTO record_properties (resource_id, property_uri, property_key, value_type, value_text)
VALUES 
    (expr_id, 'http://urn.fi/URN:NBN:fi:schema:bffi:isTranslation', 'isTranslation', 'literal', 'true');
```

**record_work_summary** (derived):

```sql
-- Work-level language = original language of the work
UPDATE record_work_summary 
SET language = 'eng'  -- from 041 $h or 008 fallback
WHERE resource_id = work_id;
```

### Query Examples

```sql
-- Find all Finnish expressions
SELECT r.uri, r.label
FROM record_resources r
JOIN record_properties p ON r.id = p.resource_id
WHERE p.property_key = 'languageOfExpression' AND p.value_text = 'fin';

-- Find all translations
SELECT r.uri, r.label
FROM record_resources r
JOIN record_properties p ON r.id = p.resource_id
WHERE p.property_key = 'isTranslation' AND p.value_text = 'true';

-- Find Finnish translations of English works
SELECT r.uri, r.label
FROM record_resources r
JOIN record_properties lang ON r.id = lang.resource_id AND lang.property_key = 'languageOfExpression'
JOIN record_properties orig ON r.id = orig.resource_id AND orig.property_key = 'originalLanguage'
WHERE lang.value_text = 'fin' AND orig.value_text = 'eng';
```

---

## Work Clustering & Human Review

### Problem

Multiple MARC21 records can represent **different Expressions of the same intellectual Work**. To build a correct WEMI model, we must group records into Works. Example:

```
Harry Potter and the Philosopher's Stone  (eng, we have this record)
Harry Potter ja viisasten kivi           (fin translation)
Harry Potter och de vises sten           (swe translation)
```

These are **three Expressions of one Work**. But how do we know they belong together?

### Decision Model: Deterministic Auto-Accept + Human Review

We use a **tiered pipeline**. Deterministic rules auto-accept the clear majority; only genuinely ambiguous candidates go to a **human review queue** with batch approval. Human judgment is the final authority, which is the right call for authority control and data precision. An LLM-assisted tier may be built later as an optional extension, but the initial scope starts with **human approval only**.

**Decision rules:**

| # | Situation | Action |
|---|-----------|--------|
| 1 | Shared identifier (010 LCCN, 001/003, existing work URI) + creator + same `work_type` + date-compatible | **Auto-accept** |
| 2 | Uniform title (130/240) + normalized creator + same `work_type` | **Auto-accept** |
| 3 | Same-language identical normalized title + normalized creator + same `work_type` + date-compatible | **Auto-accept** |
| 4 | Same-language near-match (edit distance) + same creator + same `work_type` + date-compatible | **Auto-accept** |
| 5 | Explicit translation link (`translationof` / `translatedas`), **not** an adaptation, **no free-translation marker** | **Auto-accept** |
| 6 | `is_translation=1` and `original_language` matches candidate work, **no adaptation marker** | **Auto-accept** |
| 7 | Cross-language, no uniform title, no translation link | **Human review** |
| 8 | Partial title / ambiguous creator / anonymous / no creator | **Human review** |
| 9 | **Adaptation** relationship detected (film/derivative, `adaptationof`) | **Do not merge** — link as related Work; human-only if genuinely ambiguous |
| 10 | **`work_type` mismatch** (serial vs monograph) | **Do not merge** |
| 11 | Title + creator match but **date/edition conflict** | **Human review** |
| 12 | **Creator identity uncertain** (same name, ambiguous date/identifier) | **Human review** |
| 13 | **Free translation** detected (explicit designator: `freelyTranslatedAs` / 700/758 `$i` "freely translated", "retold", "paraphrased", "rendered as", or a translation hint with no target-language title form) | **Do not merge** — link as related Work via `freelyTranslatedFrom`/`freelyTranslatedAs`; human-only if genuinely ambiguous |

> **Confirmations (defaults):**
> - **Adaptations** are never auto-merged; they become separate Works linked via `adaptationof`/related-Work relationship. If a relationship is genuinely ambiguous, it goes to the human queue.
> - **Free translations** are never auto-merged either. Per RDA, a translation that is creative enough forms a *new* Work of its own, related to the source Work as freely translated (not as the same Work in another language). They are linked via `freelyTranslatedFrom`/`freelyTranslatedAs` instead of merged.
> - **Date compatibility** uses a broad tolerance (e.g., publication dates within the same era / reasonable window, or same stemming edition). Exact-year equality is *not* required; an obviously conflicting date on an otherwise identical title+creator forces human review.
> - **Reversal/un-merge** in v1 is a simple "mark reverted + note" record with a stored snapshot for restoring prior separate-Work state.

### Candidate Review Queue Table

Rules 7, 8, 11, 12 (cross-language, ambiguous creator/anonymous, date/edition
conflict, creator identity uncertain) and 13 (free translation without an
explicit designator — see [Free translations are new Works](#free-translations-are-new-works))
produce candidate pairs stored in a dedicated
table. Rules 9, 10 and 13-with-designator (adaptation, work_type mismatch,
explicit free translation) are hard blocks and do not
enter the queue. Only candidates reaching the queue require human decision.

```sql
CREATE TABLE work_match_candidates (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    resource_a_id       BIGINT UNSIGNED NOT NULL,  -- FK to record_resources
    resource_b_id       BIGINT UNSIGNED NOT NULL,
    match_tier          TINYINT NOT NULL,          -- tier that generated this candidate

    -- Classification of the relationship (drives rule 9/10/13 gates)
    relationship_type   ENUM('translation','edition','adaptation','freetranslation','unknown')
                           DEFAULT 'unknown',
    work_type_a         VARCHAR(32),               -- 'serial' | 'monograph'
    work_type_b         VARCHAR(32),

    match_evidence      JSON,                      -- title/creator/language/date/edition comparison

    status              ENUM('pending','accepted','rejected','skipped','reverted')
                           DEFAULT 'pending',
    review_note         VARCHAR(1024),
    reviewed_by         VARCHAR(128),
    reviewed_at         TIMESTAMP NULL,
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    -- Reversal (un-merge) support
    reverted_from       BIGINT UNSIGNED NULL,      -- FK to the merged work_match_candidates.id
    work_snapshot       JSON,                      -- prior separate-Work state for restore

    -- Optional, for the future LLM original-title suggestion tier.
    -- Never authoritative; only evidence shown to the reviewer.
    suggested_original_title   VARCHAR(1024) NULL,
    suggested_title_confidence DECIMAL(4,3)  NULL,

    UNIQUE KEY (resource_a_id, resource_b_id),
    KEY (status),
    KEY (created_at),
    KEY (relationship_type),

    CONSTRAINT fk_wmc_a FOREIGN KEY (resource_a_id) REFERENCES record_resources(id) ON DELETE CASCADE,
    CONSTRAINT fk_wmc_b FOREIGN KEY (resource_b_id) REFERENCES record_resources(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### Batch Review Workflow

1. **Candidate generation** runs periodically (or on-demand after a conversion run).
2. Records that match by rules 1–6 are merged automatically; rules 7–8 become `work_match_candidates` rows with `status='pending'`.
3. A **reviewer opens the queue**, filters by status/date, and sees candidates in batches of N (e.g., 20 at a time).
4. For each candidate the UI shows side-by-side evidence (title, creator, language, uniform title, identifiers) plus the system's soft suggestion.
5. The reviewer **approves or rejects the batch** (or individually), leaving a `review_note`.
6. Accepted candidates are merged into a shared `Work`; rejected/skipped remain as separate Works.

### Review UI (Koha Plugin)

A web page in the plugin controller + template:

**List view**
- Table of `work_match_candidates` with `status='pending'`
- Filters: by date range, by batch, by evidence type
- Batch selection checkboxes

**Detail view** (per candidate)
- Two columns: Record A vs Record B
- Fields shown: title, creator (with authority signals: date, ISNI/VIAF), language,
  original_language, uniform title, identifiers, format, work_type (serial/monograph),
  publication date, edition statement
- Badge showing `relationship_type` (translation / edition / adaptation / **free translation** / unknown)
- Suggestion banner: "System suggests: likely same Work (evidence: ...)"
- (Future) "System suggests original title: ..." hint when the LLM tier is enabled
- Actions: **Accept as same Work** / **Reject** / **Reject as different Work (adaptation)** / **Reject as new Work (free translation)** / **Skip** / **Back**
  - The **free translation** action links the two Works via `freelyTranslatedFrom`/`freelyTranslatedAs` (a related-Work link, no merge) and records `relationship_type='freetranslation'`.

**Batch actions**
- "Accept all selected" / "Reject all selected" (with optional note)
- Confirmation dialog before committing merges
- On already-merged pairs: "Un-merge" action, which creates a `reverted` record
  with `work_snapshot` for restore
- Full audit trail (`reviewed_by`, `reviewed_at`, `review_note`)

### Merging Into Works

Once a candidate is accepted, the clustering logic:
1. Creates (or reuses) a single `Work` row.
2. Sets the Work's `original_language` from the expression with the earliest/original language.
3. Links each accepted Expression to that Work via `record_links` (`hasExpression` / `expressionOf`).
4. Rebuilds affected `record_work_summary` rows.

### Identifying the Original Record

For each Work cluster we must determine which Expression (if any) is the
**original record** — the record whose own language is the Work's original
language and which is not a translation. The original record may:
- **A.** Already exist in the local database, or
- **B.** Need to be found in an **external source** (OCLC, Library of Congress,
  Fennica / National Library of Finland, etc.) because it will likely never be
  imported locally.

**Decision rules (in priority order):**

| # | Signal | Meaning | Result |
|---|--------|---------|--------|
| 1 | Local Expression `language == original_language` AND `is_translation == 0` | Record in the Work's source language, not a translation | **This is the original (local)** → `original_resource_id` set |
| 2 | Local Expression has no `041 $h`, and its language equals the cluster's `original_language` | Language matches source, no translation marker | **This is the original (local)** → `original_resource_id` set |
| 3 | Local Expression `is_translation == 1` (own language differs from `original_language`) | Record is a translation | **Not the original** |
| 4 | Only translations exist locally, but the original is matched/found **externally** | Looked up via identifier / uniform title in an external authority/source | **Original found externally** → `original_external_id` set |
| 5 | Only translations exist locally, no external match yet | Original not yet identified anywhere | **No original** → `original_pending = 1` |

**The MARC evidence behind each Expression's "own language" vs "original language":**

- **own language** = `041 $a` (or `008[35-37]` fallback) — the language of this record's text
- **original_language** = `041 $h` (or, when absent, inferred from the 130/240 uniform title language, or the fallback rule above)
- **is_translation** = `1` when `own language != original_language`

**Work-level original_language resolution** (used by rules 1–2):
1. If any translation has `041 $h` → that value is the Work's `original_language` (highest confidence).
2. Else if records share a uniform title (130/240) whose language differs → that language.
3. Else if all records share the same `own language` → that language, `is_translation=0` (no translations).
4. Else → `original_pending = 1` until an authoritative original is found.

**External original lookup (rule 4):** when the local DB has only translations,
search an **external source** for the original record using the strongest available
fingerprint (identifier like LCCN/OCLC/ISBN when present, else uniform title +
creator). Match candidates are surfaced in the **same human review queue** so a
cataloger confirms before the external record is linked. The external record is
stored as a **Work/Expression resource** with `source_format='imported'` and
`source_record` pointing to its external origin — it need *not* be a local biblio.

**Late-arriving / external originals:** Both a locally imported original and an
externally matched original satisfy the same `original_pending` resolution. Because
clustering is re-runnable, either kind is attached automatically on the next pass,
setting `original_resource_id` (local) or `original_external_id` (external) and
clearing `original_pending`.

### Adaptations vs. Translations

A **translation** of a Work is the *same* Work in a different language, so it should
merge. An **adaptation** (film, abridgment-as-new-work, derivative) is a *different*
FRBR Work, even though it is based on another Work — it must **not** merge.

The `relationship_type` on `work_match_candidates` classifies each candidate:

| MARC signal | Relationship | Merge? |
|-------------|--------------|--------|
| 765 → `translationof` | translation | merge |
| 767 → `translatedas` | translation | merge |
| 775 → `otheredition` | same Work, different Expression | merge |
| 758 / 700 `$i` "is adaptation of" / `adaptationof` | **different Work (adaptation)** | **do not merge** |
| 700 `$i` "is a film adaptation of" | **different Work** | **do not merge** |

**Refined rule 6:** a translation merge is auto-accepted only when the relationship
is explicitly a translation *and* no adaptation marker is present. Any adaptation
signal forces the candidate into rule 9 (**do not merge**) or, if ambiguous, the
human queue.

### Free Translations Are New Works

RDA treats a translation that is creative enough as a **new Work** of its own —
a *freely translated* work — related to the source Work, not as an Expression of
it. This sits between the two extreme buckets of "translation → merge" and
"adaptation → separate Work".

**Decision:** free translations are **never auto-merged** (rule 13). They become
distinct Works linked back to the source via `freelyTranslatedFrom` /
`freelyTranslatedAs` (mirroring the `translationof`/`translatedas` naming, mapped
to RDA/LOC free-translation or `relatedWork` vocabulary). Only pairs that are
genuinely ambiguous reach the human queue.

| MARC signal | Relationship | Merge? |
|-------------|--------------|--------|
| 700/758 `$i` designator "freely translated", "retold", "paraphrased", "rendered as", "adapted as book" | `freetranslation` | **do not merge** — link via `freelyTranslatedAs`/`freelyTranslatedFrom` |
| 765 → `translationof` / 767 → `translatedas` + target-language title shows **no** trace of the source title (different invented title) | `freetranslation` | **do not merge** — human queue |
| 765/767 translation link, no free-translation marker, recognizable translation title | `translation` | merge |
| 041 `$h` translation, no other marker | `translation` | merge |

**Worked example — Tagore's গীতাঞ্জলি (Gitanjali):**
- Finnish translations by Eino Leino (*Uhrilauluja*) and Hannele Pohjanmies
  (*Gitanjali*) are ordinary translations of the Bengali original → merge into one
  Work (rule 6, or rule 7 → human review when 041 `$h` is absent).
- Tagore's own English *Song Offerings* is a *self-translation* that many treat as
  a **separate English Work**, not an Expression of the Bengali গীতাঞ্জলি. If a
  cataloger marks it as free translation (or the reviewer accepts the
  `freetranslation` classification), it becomes a related Work linked via
  `freelyTranslatedFrom`/`freelyTranslatedAs`; it never merges.
- The **original** is the Bengali গীতাঞ্জলি, which Fennica will not hold. If only
  translations are local, rule 4 triggers: look up the Bengali original
  externally (LoC/OCLC) or leave `original_pending = 1` until it is found.

### Same Title, Different Work (false positives)

Distinct Works can share a title+creator ("1984", same-title-different-author,
re-editions). To prevent false auto-merges, rules 1, 3, 4 require date compatibility
and matching `work_type`, and include the edition statement (250) as evidence:

| Disambiguator | Source | Role |
|---------------|--------|------|
| Work type | Leader/07 + 008/21 (`i`/`s`=serial, `a`=monograph) | must match to auto-accept |
| Publication date | 264 `$c` / 008[07-10] / 008[11-14] | conflicting eras force human review |
| Edition statement | 250 | shown as corroborating evidence |
| Series/ISSN | 490/440/022 | serial identity vs monograph |

### Serial vs. Monograph (Work boundary)

Serials and monographs behave differently and must not be merged with each other:

- `work_type` is derived from **Leader/07 and 008/21**: `i`/`s` = continuing resource,
  `a` = monograph.
- **Never auto-merge a serial with a monograph** (rule 10).
- For serials, Work identity is keyed on **ISSN + title** (the journal is one Work),
  not on individual issues. Issues are `partOf` the host Work via
  `record_component_parts`, not sibling Works.
- Multi-volume monographs are a single Work with `partNumber`/`partName` expressions.

### Creator Ambiguity (authority matching)

Creator identity must be resolved before clustering is trusted; authority matching
reuses `record_agent_summary` + the agent dedup pattern:

- NACO-normalize creator names (`name_normalized`).
- Group variant spellings of the same person into an **authority cluster**.
- **Same normalized name alone is NOT sufficient** for auto-accept. Require at least
  one corroborating signal:
  - shared creator dates (100 `$d` birth/death), **or**
  - shared identifier (ISNI, VIAF, LC authority number), **or**
  - a matching uniform title / title.
- **Anonymous / no-creator works** are never auto-accepted; title-only matching is
  too risky (rule 8 → human review).
- **Distinguish distinct authors with identical names** (e.g., two "Smith, John")
  via date/identifier; if unresolved → human review.

### Transitive Merge & Reversal

- **Transitivity:** when A~B and B~C both match, the system does not force a
  decision on A vs C. It clusters A, B, C together only if every edge leading to the
  same Work is confirmed. If the match chain is inconsistent (A~B, B~C, but A≠C),
  the conflict is surfaced to the reviewer rather than auto-ingested.
- **Reversal (un-merge):** if a merge is later found wrong, a `status='reverted'`
  row is created with `reverted_from` pointing to the original decision and a
  `work_snapshot` (JSON) capturing the prior separate-Work state. This enables a
  clean restore and preserves the audit trail.

### Why Human Approval (Not LLM)

- **Precision:** merging the wrong records corrupts the Work tree; human judgment avoids false merges.
- **Authority control:** library practice treats work-identity decisions as cataloguing decisions made by staff.
- **Auditability:** every merge has a recorded decision for correction and reporting.
- **Determinism:** same input always yields the same clustering; no model-drift between re-runs.

> **Distinction:** The *merge decision* is always human. An LLM may assist only with **evidence**, never with the decision itself.

### LLM-Assisted Original Title Suggestion (Low-Risk, Optional)

Librarians cannot be expected to recognize original titles in all languages
("Harry Potter ja viisasten kivi" vs "Harry Potter and the Philosopher's Stone").
An LLM is well suited to this **because it only produces a suggestion** that is
stored as evidence and shown to a human in the review queue — it never makes the
merge decision, so a wrong guess cannot corrupt the Work tree.

**Scope:** This is a **future, optional extension**. The initial build ships
without it; the schema and UI are designed so it can be added later without redesign.

**How it would fit (when built):**

1. **Preprocessing:** for each Expression flagged `is_translation=1` without a
   resolvable uniform title, send (title, creator, original_language) to the LLM.
2. **Output:** a proposed `original_title` string + confidence score, stored on the
   candidate as *suggested* evidence (never authoritative).
3. **Review queue:** the suggestion appears in the side-by-side detail view
   ("System suggests original title: ..." with a link to candidate Works sharing
   that title).
4. **Human confirmation:** the reviewer sees the LLM hint but still decides the
   merge; if accepted, `original_title` may be promoted to the Work's title.

**Storage:** a nullable `suggested_original_title` / `suggested_title_confidence`
column on `work_match_candidates` (or on the Expression resource as a `suggested`
property). Final decisions remain in human-controlled fields.

**Guards:**
- LLM output is never auto-written to the authoritative title.
- Low-confidence suggestions are not even pre-filled into the queue — they just
  surface as hints.
- All LLM use is batch and auditable, consistent with authority-control practice.

### Open Questions (Refine After Real Data)

1. Confirm the actual `format`/`schema` values in `biblio_metadata` before writing the candidate SQL.
2. Assess 130/240 population (using the earlier SQL) to determine how many records resolve in rules 2 vs fall to Tier 3.
3. Decide the default oracle batch size and whether auto-accepted merges need audit visibility.
4. If the original-title LLM extension is pursued: which languages matter most, and which provider/embedding model to use.
5. **External original lookup:** which external sources are reachable (OCLC, Library of Congress, Fennica / National Library of Finland) and what protocols (SRU/Z39.50/z3950 API)? Decide whether to store the external record as a linked Work/Expression resource or only as a link reference.
6. **External identifier policy:** which identifiers (LCCN, OCLC number, ISBN) are reliable enough to seed the external lookup without false matches.
7. **Adaptation detection:** how common are `adaptationof` / film-adaptation relationships (758, 700 `$i`) in the data, and how aggressively should the adaptation gate act? (Check the ratio via the earlier ExtractValue-style queries.)
8. **Mercy of date tolerance:** what is an acceptable publication-date window for treating identical title+creator as the same Work, before forcing human review?
9. **Creator authority coverage:** how many records have creator dates (100 `$d`) or identifiers (ISNI/VIAF) available to corroborate authority identity, versus relying only on normalized name?
10. **Serial fraction:** what share of records are continuing resources (Leader/07 or 008/21 `i`/`s`)? This determines how much serial-specific Work boundary logic matters.
11. **Free-translation frequency:** how common are explicit free-translation designators (700/758 `$i` "freely translated", "retold", "paraphrased") in the data, and how many translation pairs show an invented (non-translating) title that would trigger the rule-13 human queue?

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
ES is a derived search index, never the source of truth.

Configuration is **plugin-specific** (decoupled from Koha's own Elasticsearch),
read from the `bibframe_manager` koha-conf.xml stanza, the `BIBFRAME_ES_*`
environment variables, or constructor arguments (`es_server`, `es_index`,
`es_username`, `es_password`, `es_enabled`). Sync is gated by `es_enabled`
(default **off**) so the external ES dependency never breaks ordinary storage.
Exposed via `Modules/SearchIndex.pm` and `cronjobs/sync_search_index.pl`.

### Document model selection

The `config/es_mapping.yaml` `model:` key selects the document model:

- **`loc-3`** (default) — one flattened document per biblio built from the
  LoC 3-level store (work + agents/subjects/instance/parts).
- **`wemi-4`** — same flattening, plus a derived `expressions` array under
  `work`. The Expression level is computed **at index time** by feeding the
  stored LoC triples (`BibframeGenerator->generate_triples`) into
  `Bibframe::derive_wemi_from_loc`; it is never persisted. LoC 3-level stays
  canonical.
- **`loc-raw`** — one document per stored LoC entity (Work, Instance, Agent,
  Topic, ...), `_id` = resource URI, preserving the original BIBFRAME entity
  structure. Built via `build_documents`.

Index names are namespaced per model (`<index_prefix>_<model>`, e.g.
`bibframe_entities_loc-3`, `bibframe_entities_wemi-4`, `bibframe_entities_loc-raw`)
so distinct models can coexist. An explicitly configured `es_index` is used
verbatim (no suffix). Override the model at runtime with the `--model` cronjob
option or the `BIBFRAME_ES_MODEL` env var, and at build time via the
`es_model` constructor argument.

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

### Search Integration Strategy

**Recommendation: Option 1 (plugin's own search) + lightweight bridge into Koha.**

The Elasticsearch index is currently write-only — `SearchIndex.pm` indexes
documents but has no search/query method, and there is no API endpoint to
search the index. To make BIBFRAME data discoverable, two additions are needed:

#### Part A: Plugin-internal ES search (Option 1)

The plugin provides its own full-text search interface, querying the
`bibframe_entities_*` indices directly. No Koha core files are modified.

| Component | What | Why |
|-----------|------|-----|
| `SearchIndex.pm` query methods | Add `search($query, %opts)` and `suggest($prefix)` to `Modules/SearchIndex.pm`. Uses `Search::Elasticsearch->search()` against the plugin's own index. Supports multi-field query (`work.label`, `agents.name`, `subjects.term`, `manifestation.publisher`), faceted filtering (language, agent role, subject type, publication date), and autocomplete via the `suggest` field. | The index is read/write, not write-only. |
| `GET /bibframe/search` API route | New endpoint in `BibframeController.pm` + `openapi.yaml`. Accepts `q` (query string), `model` (loc-3/wemi-4/loc-raw), `limit`, `offset`, and optional facet filters. Returns a paginated result list with `biblio_id`, `work.label`, `agents`, `manifestation.date`, and a relevance score. | Exposes ES search to the Vue frontend and any external consumer. |
| Search results Vue component | New component extending the existing `SearchRecords.js` pattern. Free-text input, result cards with Work title / agents / publication info, facet sidebar (language, subject, date range), and a "View BIBFRAME" action that loads the full entity graph via the existing `/bibframe/summary` endpoint. | Users can search the BIBFRAME index without leaving the plugin tool. |

#### Part B: Lightweight bridge into Koha's search results

A small JS injection places a "BIBFRAME" link on Koha's existing OPAC/staff
client search results and detail pages, deep-linking into the plugin tool.

| Component | What | Why |
|-----------|------|-----|
| `intranet_client_js` / `opac_client_js` hook | Plugin registers a small JS snippet via Koha's plugin system. On catalog search results and detail pages, it adds a link/button per biblio: `/cgi-bin/koha/plugins/run/plug -p Koha::Plugin::Fi::KohaSuomi::BibframeManager&cl=tool&biblio_id=N`. | Users see BIBFRAME where they already search — no navigation to a separate tool required. |
| Deep-link param in `tool.tt` | The Vue app reads `biblio_id` from the URL query string. If present, it auto-loads that record's BIBFRAME graph (via `/bibframe/summary`) instead of showing the empty search form. | Seamless hand-off from Koha's search → plugin's BIBFRAME view. |

#### Why not modify Koha's core search?

Modifying `opac-search.pl`, `results.tt`, or staff client result templates is
technically possible but architecturally wrong for a plugin:

- **Upgrade fragility** — every Koha release could break patched templates.
- **Plugin boundary** — plugins extend via hooks, not by patching core files.
- **Maintenance burden** — tracking upstream changes to Koha's search UI.
- **Installation barrier** — admins hesitate to install plugins that alter
  core behavior.

The Option 1 + bridge approach keeps the plugin **self-contained** while still
being visible from Koha's native search. The hard part (data pipeline: MARC →
semantic tables → summary tables → ES sync → documents) is already built; the
query side is a small addition on top.

#### Updated implementation phases

| Phase | What | Description |
|-------|------|-------------|
| 21 | ES search methods | Add `search()` and `suggest()` to `Modules/SearchIndex.pm`. Multi-field query, faceted filtering, autocomplete. |
| 22 | Search API endpoint | `GET /bibframe/search` in `BibframeController.pm` + `openapi.yaml`. Query params: `q`, `model`, `limit`, `offset`, facet filters. |
| 23 | Search results UI | Vue search results component with free-text input, result cards, facet sidebar, "View BIBFRAME" deep-link to entity editor. |
| 24 | Koha search bridge | `intranet_client_js` / `opac_client_js` hook injecting per-biblio "BIBFRAME" links into Koha's search results and detail pages. Deep-link param in `tool.tt` for auto-loading. |

---

## Data Flow

```
MARC21 Record ──→ MARC Parser ──┐
                                 ├──→ Semantic Normalizer ──→ record_resources ──┬──→ Summary Rebuilder ──→ Summary Tables
BIBFRAME RDF ───→ RDF Parser ───┘    (dedup, extract,       record_properties     │                         record_work_summary
                                      link entities)        record_links          │                         record_manif_summary
                                                                                │                         record_agent_summary
                                                                                │
                                                                                ├──→ Work Clusterer ──→ merge Expressions ──→ work_match_candidates
                                                                                │       (rules 1–6 auto-merge,              (rules 7–8 pending)
                                                                                │        7–8 → review queue)                        │
                                                                                │                                           Human Review UI
                                                                                │                                           (batch approve)
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

### Work Clustering Step (after storage)

1. **Preprocess:** normalize titles, NACO-normalize creators, extract language + original_language + identifiers.
2. **Auto-merge (rules 1–6):** shared identifier, uniform title, identical title, near-title, explicit translation link, `is_translation`+`original_language`.
3. **Hard blocks (rules 9, 10, 13):** adaptation, work_type mismatch, explicit free translation → separate Work linked via related-work/free-translation link; never auto-merged.
4. **Human review (rules 7–8, 11–13-ambiguous):** cross-language / ambiguous / date-conflict / free-translation-without-designator candidates → `work_match_candidates` with `status='pending'`.
5. **Merge on approval:** accepted candidates create/reuse a single `Work`, link Expressions, rebuild summaries. Free translations are linked (`freelyTranslatedFrom`/`freelyTranslatedAs`) instead of merged.

### Writing Data

1. **MARC21 → Storage:** Parse MARC21, create `record_resources` + `record_properties` + `record_links`. Store MARC21 in `record_format_mappings`. Rebuild summary tables.

2. **BIBFRAME → Storage:** Parse RDF, create `record_resources` + `record_properties` + `record_links`. Store BIBFRAME in `record_format_mappings`. Rebuild summary tables.

### Reading Data

1. **Common queries:** Read from summary tables (fast). Example: `SELECT * FROM record_work_summary WHERE language = 'fin'`.

2. **Full graph:** Read from core tables. Example: traverse `record_links` to build the complete Work → Instance → Item chain (LoC canonical stored model).

3. **Export to MARC21:** `Modules/MarcGenerator.pm` returns the authoritative saved MARC copy from `record_format_mappings` (`format_name='marc21'`), falling back to Koha `biblio_metadata` (Phase 10).

4. **Export to BIBFRAME (LoC 3-level):** `Modules/BibframeGenerator.pm` reads core tables and builds LoC 3-level RDF triples from `record_resources` + `record_properties` + `record_links` (Phase 11a).

5. **Export to BFFI (4-level WEMI):** `Modules/BFFIGenerator.pm` feeds the BibframeGenerator LoC 3-level triples through `Bibframe::derive_wemi_from_loc` to derive the Work → Expression → Manifestation → Item graph on export. The Expression level is derived on demand and never persisted (Phase 11b).

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

### "Show all Expressions belonging to a Work cluster"

```sql
SELECT r.id, r.uri, r.label,
       p_lang.value_text AS language
FROM record_resources r
JOIN record_links l ON l.target_resource_id = r.id
LEFT JOIN record_properties p_lang
       ON p_lang.resource_id = r.id AND p_lang.property_key = 'languageOfExpression'
WHERE l.source_resource_id = /* the merged Work resource_id */
  AND l.relationship_type = 'hasExpression'
ORDER BY p_lang.value_text;
```

### "List open review queue (pending candidates)"

```sql
SELECT c.id, c.match_tier, c.created_at,
       a.label AS title_a, b.label AS title_b
FROM work_match_candidates c
JOIN record_resources a ON c.resource_a_id = a.id
JOIN record_resources b ON c.resource_b_id = b.id
WHERE c.status = 'pending'
ORDER BY c.created_at
LIMIT 20;
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
| 6 | Language detection | Add `_detect_original_language()` to `Bibframe.pm` — extracts original language from MARC 041 $h or 008 |
| 7 | Semantic normalizer | `Modules/SemanticStore.pm` — converts MARC21/BIBFRAME to semantic primitives |
| 8 | Summary rebuilder | `Modules/SummaryRebuilder.pm` — rebuilds summary tables from core tables |
| 9 | Component parts sync | `Modules/ComponentPartsSync.pm` — populate `record_component_parts` from `record_links`. `sync_all()` rebuilds from all containment links; `sync_for_resource($id)` rebuilds rows where a resource is component or host. Handles `partOf` (component→host), `hasPart` (host→component, stored canonically as component→host) and `supplement`/`supplementTo`. Host reference metadata (title, uri, issn, control-number, volume, label, source MARC tag) copied from `record_links.properties_json`. Integrated into `SemanticStore._rebuild_summaries`. |
| 10 | MARC21 generator | `Modules/MarcGenerator.pm` — semantic store → MARC21. Returns the authoritative saved MARC copy from `record_format_mappings.format_name='marc21'`, falling back to Koha `biblio_metadata`. `SemanticStore::get_record` + `_save_format_mapping` persist/read the copy. |
| 11a | LoC BIBFRAME generator | `Modules/BibframeGenerator.pm` — reads core tables (`record_resources`/`record_properties`/`record_links`) and emits LoC 3-level (Work → Instance → Item) RDF triples. Default export standard. |
| 11b | BFFI 4-level WEMI generator | `Modules/BFFIGenerator.pm` — derives the 4-level WEMI (Work → Expression → Manifestation → Item) from the stored LoC 3-level graph via `Bibframe::derive_wemi_from_loc` on BFFI export only. Expression is never persisted. |
| 12 | Elasticsearch sync | `Modules/SearchIndex.pm` — builds `record_entities` documents from summary + core tables (work/agents/manifestation/component_parts/suggest) and syncs to ES. The BIBFRAME→document field mapping is declarative: `config/es_mapping.yaml` (loaded by `Modules/Esmapping.pm`) maps semantic storage shapes onto doc fields, so SearchIndex is data-driven rather than hardcoded. Plugin-specific config (decoupled from Koha's ES), read from the `bibframe_manager` koha-conf.xml stanza / `BIBFRAME_ES_*` env / constructor args. Sync is off by default (`es_enabled`), so the external ES dependency never breaks ordinary storage. **Configurable document models** via the `es_mapping.yaml` `model:` selector: `loc-3` (default, one flattened doc per biblio), `wemi-4` (adds a derived `expressions` array under `work`, computed at index time via `Bibframe::derive_wemi_from_loc` from the stored LoC triples — Expression is never persisted, LoC 3-level stays canonical), and `loc-raw` (one doc per stored LoC entity, `_id` = resource URI; via `build_documents`). Index names are namespaced per model (`<index_prefix>_<model>`): `bibframe_entities_loc-3` / `_wemi-4` / `_loc-raw`, and an explicitly configured `es_index` is used verbatim. API: `ensure_index`, `build_document`, `build_documents`, `index_document`, `index_biblios`, `delete_document`, `rebuild_all`, `sync_biblio`; integrated into `SemanticStore._sync_search_index`; cronjob `cronjobs/sync_search_index.pl` (`--all/--biblionumber/--file/--range/--index/--delete/--model`). |
| 13 | API updates | `Modules/SummaryReader.pm` — reads the API's fast side from the typed summary tables (`record_work_summary`, `record_instance_summary`, `record_agent_summary`) instead of `biblio_metadata`. `get_for_biblio($biblio_id)` → work + instances + agents; `get_work_for_biblio`, `get_work`, `get_instances_for_biblio`, `get_instance`, `get_agents_for_work` (agents joined via `record_links` creator/contributor with role aut/ctb). Served by `BibframeController::summary` (`GET /bibframe/summary?biblio_id`) added to `openapi.yaml`. |
| 14 | Match candidate DDL | Create `sql/05_work_clustering.sql` (wired into `install()` / `upgrade()` / `uninstall()`) with `work_match_candidates`, `relationship_type` ENUM incl. `freetranslation` |
| 15 | Clustering engine | `Modules/WorkClusterer.pm` — deterministic rules 1–13 (incl. adaptation, work_type, date, creator-authority gates, free-translation designator) auto-merge or route to review |
| 16 | Review queue UI | Controller + template for batch human review of `work_match_candidates` (relationship_type, work_type, adaptation action, **free translation → link as related Work**) |
| 17 | Merge materialization | Accept → create/reuse Work, link Expressions, rebuild summaries; support un-merge reversal |
| 18 | External original lookup | `Modules/ExternalOriginal.pm` — query external sources (OCLC/LOC/Fennica) for rule-4 originals; surface matches in review queue |
| 19 | Creator authority matcher | `Modules/AuthorityMatcher.pm` — cluster agents, corroborate identity via dates/ISNI/VIAF |
| 20 | *(Future, optional)* LLM original-title tier | Suggest `suggested_original_title` as evidence only; human still decides |
| 21 | ES search methods | Add `search()` and `suggest()` to `Modules/SearchIndex.pm`. Multi-field query, faceted filtering, autocomplete via the `suggest` field. |
| 22 | Search API endpoint | `GET /bibframe/search` in `BibframeController.pm` + `openapi.yaml`. Query params: `q`, `model`, `limit`, `offset`, facet filters. Returns paginated results with biblio_id, work label, agents, manifestation date, relevance score. |
| 23 | Search results UI | Vue search results component with free-text input, result cards, facet sidebar (language, subject, date range), "View BIBFRAME" deep-link to entity editor. |
| 24 | Koha search bridge | `intranet_client_js` / `opac_client_js` hook injecting per-biblio "BIBFRAME" links into Koha's search results and detail pages. Deep-link param in `tool.tt` for auto-loading via `/bibframe/summary`. |

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
| Language & translation handling | Plan A + B | Original language + is_translation flags for WEMI |
| Work clustering & human review | New | Deterministic auto-merge + batch human-approval queue (no LLM); adaptations and free translations never auto-merge (link as related Works) |
| Expression persistence | Decided | LoC 3-level canonical; Expression derived only (BFFI export / `wemi-4` ES) |
| Search integration (Option 1 + bridge) | New | Plugin-internal ES search + JS bridge into Koha's native search results |
| `biblio_id` naming | Plan A | Koha community convention |
| `record_` prefix | Plan B | Format-agnostic naming |
