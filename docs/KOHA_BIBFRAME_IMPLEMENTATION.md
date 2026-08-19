# Koha BIBFRAME Implementation Plan

**Date:** 2026-08-17
**Status:** Design Document
**Author:** Johanna Räisä (assisted by opencode/big-pickle LLM)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [How Koha Core Is Used](#how-koha-core-is-used)
3. [Architecture Overview](#architecture-overview)
4. [Pros](#pros)
5. [Cons](#cons)
6. [Why This Is the Best Option for Koha](#why-this-is-the-best-option-for-koha)
7. [Implementation Roadmap](#implementation-roadmap)

---

## Executive Summary

The Hybrid Plan combines **Plan B's format-agnostic storage** with **Plan A's typed-column performance** to create a schema that:

- Stores bibliographic data in a format-agnostic way (MARC21, BIBFRAME, Dublin Core, etc.)
- Provides fast queries through materialized summary tables
- Integrates cleanly with Koha's existing database (doesn't modify Koha core)
- Supports full BIBFRAME export for linked data
- Preserves round-trip fidelity (MARC → semantic store → MARC)

**Key principle:** We extend Koha's bibliographic layer. We don't replace or modify Koha core tables.

---

## How Koha Core Is Used

The Hybrid Plan **reuses Koha's existing tables** rather than replacing them:

### Koha Core Tables (Untouched)

| Table | Purpose | Our Interaction |
|-------|---------|-----------------|
| `biblio` | Bibliographic records | Read via `biblio_id` foreign key |
| `biblioitems` | Publication details (ISBN, publisher) | Read for MARC export |
| `items` | Physical copies (barcode, location) | Read for BIBFRAME Item export |
| `biblio_metadata` | MARC records | Read for MARC export; we no longer write BIBFRAME here |
| `branches` | Library locations | Read for `heldBy` in BIBFRAME export |
| `itemtypes` | Item type codes | Read for `bf:genreForm` mapping |

### Our New Tables (Plugin-Defined)

| Table | Purpose | Replaces |
|-------|---------|----------|
| `record_resources` | Format-agnostic entity storage | Nothing (new) |
| `record_properties` | Key-value attributes on entities | Nothing (new) |
| `record_links` | Relationships between entities | Nothing (new) |
| `record_work_summary` | Fast Work-level queries | EAV pivoting |
| `record_manif_summary` | Fast Manifestation-level queries | EAV pivoting |
| `record_agent_summary` | Fast Agent browsing | EAV pivoting |
| `record_component_parts` | MARC21 773/774 ↔ BIBFRAME partOf/hasPart | Nothing (new) |
| `record_format_mappings` | Per-format serialized data | Nothing (new) |
| `record_reference_types` | Controlled vocabularies | Nothing (new) |
| `record_graphs` | Groups resources into descriptions | Nothing (new) |

### The Connection

```
Our Plugin Tables                          Koha Core Tables
─────────────────────────────────         ─────────────────────────────
record_work_summary (Work)
        │
        │ record_links (hasManifestation)
        ▼
record_manif_summary (Manifestation)
        │
        │ biblio_id = 12345
        ▼
                    biblio.biblionumber = 12345 ──→ items (physical copies)
                    biblioitems (publication details)
                    biblio_metadata (MARC records)
```

### What We Don't Touch

- **`biblio` table** — we read it, never write to it
- **`biblioitems` table** — we read it for MARC export
- **`items` table** — we read it for BIBFRAME Item export
- **`biblio_metadata` table** — Koha core uses it for MARC; we won't write BIBFRAME here
- **Circulation tables** — `issues`, `old_issues`, `reserves` — not our concern
- **Patron tables** — `borrowers`, `permissions` — not our concern

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    EXPORT LAYER                          │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ MARC21       │  │ BIBFRAME     │  │ Future       │  │
│  │ Generator    │  │ Generator    │  │ Generators   │  │
│  │ (reads from  │  │ (reads from  │  │ (DC, Schema, │  │
│  │  Koha core + │  │  our tables) │  │  etc.)       │  │
│  │  summaries)  │  │              │  │              │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                  │          │
├─────────┴─────────────────┴──────────────────┴──────────┤
│                    STORAGE LAYER                         │
│                                                         │
│  ┌─────────────────┐    ┌────────────────────────────┐  │
│  │ Summary Tables  │    │ Core Storage (Plan B)       │  │
│  │ (Plan A-style)  │    │                             │  │
│  │                 │    │ record_resources             │  │
│  │ work_summary    │◄───│ record_properties            │  │
│  │ manif_summary   │    │ record_links                 │  │
│  │ agent_summary   │    │ record_component_parts       │  │
│  └─────────────────┘    │ record_format_mappings       │  │
│                         └────────────────────────────┘  │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                    KOHA CORE (Read-Only)                 │
│                                                         │
│  biblio ←── biblioitems ←── items                       │
│  biblio_metadata (MARC only)                            │
│  branches, itemtypes, etc.                              │
└─────────────────────────────────────────────────────────┘
```

---

## Pros

### 1. Koha Core Is Untouched

| Benefit | Explanation |
|---------|-------------|
| **No Koha upgrades broken** | We don't modify any core tables. Koha upgrades continue to work. |
| **No schema conflicts** | Our tables use `record_` prefix. No naming collisions with Koha. |
| **Easy rollback** | If the plugin fails, drop our tables. Koha core is unaffected. |
| **Community compatible** | Koha community can review our plugin without reviewing core changes. |

### 2. Format-Agnostic Storage

| Benefit | Explanation |
|---------|-------------|
| **MARC21 import** | Parse MARC21 → store as semantic facts → export to any format |
| **BIBFRAME import** | Parse BIBFRAME RDF → store as semantic facts → export to MARC21 |
| **Future formats** | Dublin Core, Schema.org, ONIX — just add new parsers/generators |
| **No data lock-in** | Data is stored as facts, not format-specific encodings |

### 3. Fast Queries via Summary Tables

| Benefit | Explanation |
|---------|-------------|
| **Common queries are fast** | `SELECT * FROM record_work_summary WHERE language = 'fin'` |
| **No EAV pivoting** | Summary tables have typed columns for the most common fields |
| **Reporting works** | `GROUP BY` on typed columns, not property_key filtering |
| **ES sync is simple** | Read from summary tables, not pivot EAV rows |
| **Usability** | User's can search data more easily, more familiar structure |

### 4. BIBFRAME-Native Support

| Benefit | Explanation |
|---------|-------------|
| **Linked data ready** | Export to BIBFRAME RDF for linked data applications |
| **FRBR-LRM hierarchy** | Work → Expression → Manifestation → Item preserved |
| **Component parts** | MARC21 773/774 ↔ BIBFRAME partOf/hasPart handled natively |
| **URI-based identity** | Resources have URIs for linked data interoperability |

### 5. Backward Compatible

| Benefit | Explanation |
|---------|-------------|
| **Existing code works** | Queries against `biblio_metadata` still work during migration |
| **Gradual migration** | Move to new tables at your own pace |
| **No breaking changes** | Plugin adds new tables, doesn't remove old ones |

### 6. Koha Integration Preserved

| Benefit | Explanation |
|---------|-------------|
| **`biblio_id` links** | All our tables link to Koha via `biblio_id` |
| **Items table used** | Physical copies use Koha's existing `items` table |
| **Circulation works** | Check-in/out uses Koha's existing code |
| **OPAC works** | Koha's OPAC continues to function normally |

---

## Cons

### 1. Schema Complexity

| Challenge | Explanation |
|-----------|-------------|
| **More tables** | 10+ new tables vs current 0 custom tables |
| **Learning curve** | New developers must understand the hybrid architecture |
| **Documentation** | Must document all tables, relationships, and migration paths |
| **Validation** | Validation layer needs to be on a code level |

### 2. MariaDB Limitations

| Challenge | Explanation |
|-----------|-------------|
| **No JSONB** | MariaDB lacks PostgreSQL's JSONB operators (FOLIO uses these) |
| **No materialized views** | Must use summary tables instead |
| **Full-text search** | MariaDB FULLTEXT is less powerful than PostgreSQL's |

### 3. Performance Overhead

| Challenge | Explanation |
|-----------|-------------|
| **Summary table rebuilds** | Must rebuild summary tables when data changes |
| **EAV overhead** | Core storage uses EAV pattern (slower than typed columns) |
| **Index maintenance** | More tables = more indexes to maintain |

---

## Why This Is the Best Option for Koha

### 1. Koha Doesn't Support BIBFRAME Natively

Koha's core database structure is designed for MARC21:

| Koha Core Table | MARC21 Focus |
|-----------------|--------------|
| `biblio` | Title, author, copyright date |
| `biblioitems` | ISBN, ISSN, publisher, pages |
| `items` | Barcode, location, call number |
| `biblio_metadata` | MARC XML storage |

**Koha has no native support for:**
- Work → Expression → Manifestation → Item hierarchy
- BIBFRAME entities (Agent, Topic, Classification)
- Linked data (URIs, RDF)
- Format-agnostic storage

**The Hybrid Plan fills this gap** by adding BIBFRAME support without modifying Koha core.

### 2. Extends Koha's Database Structure

The new tables integrate with Koha's existing hierarchy:

```
Koha Core                                Our Plugin Tables
──────────────────────────              ─────────────────────────
biblio (title, author) ◄─────────────── record_manif_summary.biblio_id
    │
    ├── biblioitems (ISBN, publisher)    record_work_summary (Work)
    │
    ├── items (barcode, location)        record_agent_summary (Agents)
    │
    └── biblio_metadata (MARC XML)       record_properties (Attributes)
                                         record_links (Relationships)
                                         record_component_parts (773/774)
                                         record_format_mappings (BIBFRAME RDF)
```

**We don't replace Koha's tables. We extend them with BIBFRAME support.**

### 3. Community-Friendly

| Aspect | Benefit |
|--------|---------|
| **Plugin architecture** | Koha community can review/merge without core changes |
| **Standard naming** | `biblio_id`, `record_` prefix follow conventions |
| **Documented schema** | All tables, relationships, and migration paths documented |
| **Backward compatible** | Existing installations can migrate gradually |

### 4. Proven Pattern

The hybrid approach (generic storage + summary tables) is used by:

- **FOLIO** — JSONB + top-level columns
- **Share-VDE** — BIBFRAME + relational views
- **Sinopia** — BIBFRAME + Elasticsearch
- **Viu** — BIBFRAME + PostgreSQL materialized views

We're not inventing a new pattern. We're adapting a proven one for MariaDB.

---

## Development Strategy

### Phase 1: Plugin (Separate Development)

Build everything as a Koha plugin first:

| Task | Description |
|------|-------------|
| **Plugin architecture** | All new tables and code live in the plugin |
| **Rapid iteration** | Develop, test, and refine without core code review |
| **No core dependencies** | Plugin works independently of Koha version |
| **Easy rollback** | If something breaks, disable the plugin |
| **Community feedback** | Share plugin for early feedback before proposing core changes |

**Benefits of plugin-first approach:**
- ✅ Test with real data before proposing core changes
- ✅ Iterate quickly based on user feedback
- ✅ Prove the concept with minimal risk
- ✅ Build community support before proposing core integration

### Phase 2: Core Integration (After Plugin Is Proven)

Once the plugin is stable and the community agrees, propose features for Koha core:

| Feature | From Plugin | To Koha Core |
|---------|-------------|--------------|
| **Schema DDL** | Plugin's `install()` | Koha's installer |
| **Semantic storage** | Plugin's `record_*` tables | Core catalog module |
| **MARC export** | Plugin's `MarcGenerator.pm` | `C4::Biblio` |
| **BIBFRAME export** | Plugin's `BibframeGenerator.pm` | New `Bibframe.pm` module |
| **ES sync** | Plugin's `SearchIndex.pm` | Koha's search module |

**Why core integration makes sense eventually:**
- 📈 BIBFRAME support benefits all Koha users
- 🔗 Linked data is becoming a standard
- 🌍 Format-agnostic storage future-proofs Koha
- 🤝 Community can maintain it long-term

## Implementation Roadmap

### Phase 1: Foundation

| Task | Description |
|------|-------------|
| Create schema DDL | All new tables in `docs/sql/` |
| Install hooks | Add to `BibframeManager.pm` `install()` and `upgrade()` |
| Basic CRUD | `SemanticStore.pm` for read/write operations |

### Phase 2: Data Migration

| Task | Description |
|------|-------------|
| Parse existing data | Script to parse `biblio_metadata` RDF blobs |
| Populate new tables | Migrate to `record_resources`, `record_properties`, `record_links` |
| Rebuild summaries | Populate `record_work_summary`, `record_manif_summary` |

### Phase 3: Export Generators

| Task | Description |
|------|-------------|
| MARC21 generator | `MarcGenerator.pm` — semantic store → MARC21 XML |
| BIBFRAME generator | `BibframeGenerator.pm` — semantic store → RDF triples |
| Component parts | Populate `record_component_parts` from mapping data |

### Phase 4: Search Integration

| Task | Description |
|------|-------------|
| ES sync | `SearchIndex.pm` — MariaDB → Elasticsearch |
| Index mapping | Define ES document structure |
| Query API | Update `BibframeController.pm` for new queries |

### Phase 5: Cleanup

| Task | Description |
|------|-------------|
| Remove old code | Delete `saveBibframeMetadata()` from `Database.pm` |
| Stop dual writes | Only write to `record_format_mappings` |
| Update documentation | README, API docs, developer guides |

---

## Summary

| Aspect | Hybrid Plan |
|--------|-------------|
| **Development approach** | Plugin first, then core integration |
| **Koha core** | Read-only during plugin phase, integrated later |
| **Our tables** | 10+ new tables with `record_` prefix (in plugin) |
| **Storage** | EAV (flexible) + summary tables (fast) |
| **Usability** | Database structure is more familiar to users than fully agnostic one |
| **Formats** | MARC21, BIBFRAME, BFFI, future formats |
| **Performance** | Fast via summary tables, EAV for rare queries |
| **Migration** | Gradual, backward compatible |
| **Community** | Plugin for testing, core for production |
| **Future** | Linked data ready, ES-ready, format-agnostic |

**The Hybrid Plan is the best option for Koha because it allows us to develop and test as a plugin first, prove the concept with real data, and then propose proven features for Koha core integration. This approach minimizes risk, allows rapid iteration, and builds community support before proposing changes to the core codebase.**
