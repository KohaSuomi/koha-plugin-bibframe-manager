# Koha-Suomi Plugin: Bibframe Manager

Bibframe Manager is a Koha plugin for managing Bibframe metadata. It converts
MARC21 bibliographic records to Bibframe, stores them in a **format-agnostic
semantic store** backed by plugin-owned database tables, and provides retrieval,
export and Elasticsearch indexing.

The canonical stored form is the **LoC BIBFRAME 3-level model**
(Work → Instance → Item). The Finnish BFFI **4-level WEMI** model
(Work → Expression → Manifestation → Item) is **derived on demand** at export /
index time and is never persisted.

## Features

- Convert MARC21 records to Bibframe using either:
  - the official [marc2bibframe2](https://github.com/lcnetdev/marc2bibframe2)
    XSLT converter (LoC BIBFRAME 2.0), or
  - the plugin's own converter (Finnish BIBFRAME Implementation + derived
    4-level WEMI)
- Store Bibframe metadata in a **format-agnostic semantic store**:
  - canonical core tables (`record_resources`, `record_properties`, `record_links`)
  - typed summary tables for fast reads (`record_work_summary`,
    `record_instance_summary`, `record_agent_summary`)
  - component parts linking (MARC21 773/774 ↔ BIBFRAME `partOf`/`hasPart`)
  - per-format serialized representations and record graphs
  - a `work_match_candidates` table for work clustering (created by install,
    used by the future clustering engine)
- Export in multiple RDF formats: Turtle, JSON-LD, N-Triples, RDF/XML
- Elasticsearch indexing with configurable document models
  (`loc-3`, `wemi-4`, `loc-raw`), disabled by default
- REST API for conversion, export and summary reads
- Batch conversion and search-index sync scripts
- Vue.js-based Bibframe record builder (plugin tool) for creating
  WEMI-structured records from scratch

## Architecture

The storage follows the **hybrid plan** (see
[docs/HYBRID_PLAN.md](docs/HYBRID_PLAN.md)): a format-agnostic canonical store
(the "core") plus derived, typed summary tables for the most common query
patterns. Summary tables are rebuilt from the core whenever data changes.

Installed tables:

| Table | Purpose |
|-------|---------|
| `record_resources` | Canonical entities (Work, Instance, Item, Agent, Topic, ...); Items link to Koha's `items` table |
| `record_properties` | EAV attribute storage for all resources |
| `record_links` | Relationships between resources |
| `record_work_summary` | Derived Work-level data for fast reads |
| `record_instance_summary` | Derived Instance-level data for fast reads |
| `record_agent_summary` | Derived Agent data (authority browsing) |
| `record_component_parts` | Article/chapter/issue host–component linking (MARC21 773/774) |
| `record_format_mappings` | Per-format serialized representations (marc21, bffi, bibframe2, bibframe3) |
| `record_graphs` / `record_graph_resources` | Groups resources into coherent bibliographic descriptions |
| `work_match_candidates` | Candidate pairs for the (future) deterministic work clustering engine |

The schema is defined in `Koha/Plugin/Fi/KohaSuomi/BibframeManager/sql/*.sql`
and created on install/upgrade.

# Downloading

From the release page you can download the latest \*.kpz file

# Installing

Koha's Plugin System allows for you to add additional tools and reports to Koha that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work.

The plugin system needs to be turned on by a system administrator.

To set up the Koha plugin system you must first make some changes to your install.

    Change <enable_plugins>0<enable_plugins> to <enable_plugins>1</enable_plugins> in your koha-conf.xml file
    Confirm that the path to <pluginsdir> exists, is correct, and is writable by the web server
    Remember to allow access to plugin directory from Apache

    <Directory <pluginsdir>>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    Restart your webserver

Once set up is complete you will need to alter your UseKohaPlugins system preference. On the Tools page you will see the Tools Plugins and on the Reports page you will see the Reports Plugins.

Installing (or upgrading) the plugin runs the SQL in `sql/` to create the
plugin-owned `record_*` tables. Uninstalling drops them.

# Configuration

No special configuration is required for ordinary use. Stored records live in
the plugin-owned tables described above.

**Optional — Elasticsearch indexing** is configured plugin-specifically
(decoupled from Koha's own Elasticsearch). Set these in the
`<bibframe_manager>` stanza of `koha-conf.xml`, via the
`BIBFRAME_ES_*` environment variables, or (for programmatic use) via
constructor arguments:

| Setting | Environment variable | Default |
|---------|----------------------|---------|
| `es_server` | `BIBFRAME_ES_SERVER` | — (required when enabled) |
| `es_index` | `BIBFRAME_ES_INDEX` | `bibframe_entities` (namespaced per document model) |
| `es_username` / `es_password` | `BIBFRAME_ES_USERNAME` / `BIBFRAME_ES_PASSWORD` | — (Basic auth, optional) |
| `es_enabled` | `BIBFRAME_ES_ENABLED` | `0` (sync off by default) |

The document model is selected by the `model:` key in
`config/es_mapping.yaml`:

- `loc-3` (default) — one flattened document per biblio from the LoC 3-level store
- `wemi-4` — adds a derived `expressions` array under `work`, computed at index time
- `loc-raw` — one document per stored LoC entity, `_id` = resource URI

Because `es_enabled` defaults to off, the external Elasticsearch dependency
never breaks ordinary storage.

# Usage

## Plugin tool

In the Tools page, open *Bibframe Manager*. The tool provides a Vue-based
**Bibframe Record Builder** for creating WEMI (Work, Expression, Manifestation,
Item) records from scratch, with property suggestions, custom relationships and
export to Turtle / JSON-LD / N-Triples / RDF/XML.

## Conversion scripts

`convert_marc_to_bibframe.pl` in `cronjobs/` is the full-featured batch
conversion script, with two engines and many selection/output options.

```bash
cd Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/

# Convert a single record to an RDF/XML file (xslt engine, default)
perl convert_marc_to_bibframe.pl --biblionumber=123 --output=123.rdf

# Convert all biblios to JSON-LD files (plugin engine)
perl convert_marc_to_bibframe.pl --all --engine=plugin --format=json-ld --verbose
```

Engines:
- `--engine=xslt` (default) — runs the bundled `marc2bibframe2` XSLT converter
  over the selected records and writes a single RDF/XML file.
- `--engine=plugin` — uses the plugin's own Bibframe module (Finnish BIBFRAME
  Implementation + derived 4-level WEMI) and writes per-record files.

See [`cronjobs/README_CONVERSION.md`](Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/README_CONVERSION.md)
for the full option reference and examples.

## Elasticsearch sync

`cronjobs/sync_search_index.pl` indexes stored semantic data (summary + core
tables) into Elasticsearch:

```bash
perl sync_search_index.pl --all                          # sync everything
perl sync_search_index.pl --biblionumber=123,124,125     # specific biblios
perl sync_search_index.pl --range=1-100                  # a range
perl sync_search_index.pl --index 123                    # upsert one
perl sync_search_index.pl --delete 123                   # delete one
perl sync_search_index.pl --model=wemi-4 --all           # override document model
```

## REST API

The plugin registers API routes under `/api/v1/contrib/kohasuomi`:

| Endpoint | Purpose |
|----------|---------|
| `POST /api/v1/contrib/kohasuomi/bibframe/convert` | Convert a MARC21 record (by biblionumber, base64 MARC file, or raw MARC/XML text) to Bibframe. Standard: `bffi` or `bibframe2` (default). |
| `POST /api/v1/contrib/kohasuomi/bibframe/store` | Export a stored record from the semantic store as LoC 3-level or BFFI 4-level WEMI RDF, by `resource_id` or `biblio_id`. |
| `GET /api/v1/contrib/kohasuomi/bibframe/summary` | Read the stored semantic summary for a biblio from the typed summary tables (work, instances, agents). |

The API schema is defined in `openapi.yaml`.

# Further documentation

Additional design and analysis documentation lives in `docs/`:

- `HYBRID_PLAN.md` — the hybrid storage architecture and implementation phases
- `KOHA_BIBFRAME_IMPLEMENTATION.md` — Koha BIBFRAME implementation overview
- `BFFI_IMPLEMENTATION.md` — Finnish BIBFRAME implementation
- `PLAN_A_BIBFRAME_TABLE_STRUCTURE.md` / `PLAN_B_FORMAT_AGNOSTIC_SCHEMA.md` —
  the two storage approaches that the hybrid plan combines
- Analysis documents: FOLIO comparison, component parts, physical copies,
  biblio metadata, single reference table, pros and cons
- `MARC_TO_BIBFRAME_MAPPING.md` — MARC21 → BIBFRAME field mapping

# License

Copyright (C) 2025-2026 KohaSuomi

This plugin is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for details.