# BFFI Example vs. the Semantic Store BFFI Projection

## Purpose

This document compares the ideal BFFI record in
[`docs/BFFI-redeemedMonograph.ttl`](BFFI-redeemedMonograph.ttl) against the BFFI
that the plugin currently derives from the semantic store, explains the root
cause of the differences, and records the projection design that closes the gap.

The key architectural fact stays unchanged: **the canonical store is LoC
BIBFRAME 2.0 at three levels (Work -> Instance -> Item)**. The four-level BFFI
WEMI model (Work -> Expression -> Manifestation -> Item) is a *derived
projection*, produced on export and on index time, and is never persisted.

## 1. What the example contains

`BFFI-redeemedMonograph.ttl` (131 lines) describes one Finnish monographic
translation. It is a fully modeled BFFI 1.0.0 graph:

| Area | Terms used in the example |
| --- | --- |
| Work | `bffi:Work`, `bffi:MonographWork`, `bffi:hasExpression`, `bffi:title`, `bffi:aap`, `bffi:contribution`, `bffi:originDate`, `bffi:genreForm`, `bffi:subject`, `bffi:classification`, `bffi:adminMetadata`, `bffi:relation` |
| Expression | `bffi:Expression`, `bffi:MonographExpression`, `bffi:Text`, `bffi:expressionOf`, `bffi:manifestationOfExpression`, `bffi:aggregatedBy`, `bffi:aap`, `bffi:title`, `bffi:content`, `bffi:languageOfExpression`, `bffi:note`, `bffi:intendedAudience`, `bffi:contribution` |
| Manifestation | `bffi:Manifestation`, `bffi:Print`, `bffi:expressionManifested`, `bffi:workManifested`, `bffi:aap`, `bffi:identifiedBy`, `bffi:title`, `bffi:responsibilityStatement`, `bffi:media`, `bffi:carrier`, `bffi:contribution`, `bffi:extent`, `bffi:dimensions`, `bffi:provisionActivity`, `bffi:publicationStatement`, `bffi:manufactureStatement`, `bffi:note`, `bffi:relation`, `bffi:seriesEnumeration`, `bffi:seriesStatement` |
| Value vocabularies | MTS (`mts:`), YSO (`yso:`), Kauno (`kauno:`), SLM (`slm:`), in addition to `bffi:` |
| Authorities | `finaf:` agents, Lexvo languages, Melinda entity URIs, YSO/Kauno/SLM subject URIs |
| Structure | bnode `bffi:Contribution` / `bffi:Relation` / `bffi:Title` / `bffi:Extent` / `bffi:Classification` / `bffi:Source` / `bffi:AdminMetadata` nodes |

The example is a *target*, not a byte-for-byte contract: it carries inline
comments (`# ...`) flagging questions around `seriesEnumeration`,
`bffi:note`/MTS `motx`, YKL sub-classification, and the `bf:AdminMetadata`
blocks. It still fixes the shape of the projection.

## 2. What the plugin currently exports

The export path is:

```
stored LoC triples        BibframeGenerator::generate_triples
  -> Bibframe::derive_wemi_from_loc   (Bibframe.pm:901)
  -> serialization                    Database::serializeTriples
```

`BFFIGenerator::generate_triples` (`Modules/BFFIGenerator.pm:48`) reads the
stored LoC graph and calls `derive_wemi_from_loc` (`Modules/Bibframe.pm:901`).
`derive_wemi_from_loc` is a **level split plus a partial rename**, not a
BIBFRAME-to-BFFI remap. Concretely it:

1. Finds the first `bf:Work` and `bf:Instance` subject, preferring
   `/resources/works/` and `/resources/instances/` URIs (`Bibframe.pm:929-938`).
2. Derives a control number from the LoC path, or the last path segment
   otherwise (`Bibframe.pm:943-960`).
3. Mints an Expression URI `${base_uri}expression/${control_number}` and
   **keeps the original LoC URIs** for Work (`derived_work_uri = $work_uri`) and
   Manifestation (`derived_manifestation_uri = $instance_uri`)
   (`Bibframe.pm:962-965`).
4. Moves a fixed set of expression-level properties
   (`language editionNote note reproduction supplementaryContent contentType`)
   from the Work to the Expression (`Bibframe.pm:967-971,1007-1017`).
5. Emits only `bffi:Work`, `bffi:Expression`, `bffi:Manifestation` types
   (no sub-classes such as `bffi:MonographWork`), the `hasExpression` /
   `expressionOf` and `manifestationOfExpression` / `expressionManifested`
   links, and **never emits an Item** (`Bibframe.pm:978-1092`).
6. Copies all other Work/Instance predicates **verbatim**, so the output is a
   mixture of `bf:` and `bffi:` predicates.

The module docstring itself describes it as "Derives BFFI 4-level WEMI ...
from the canonical LoC 3-level store" (`Modules/BFFIGenerator.pm:17-27`).

## 3. Gap analysis

| Dimension | Example (target BFFI) | Current export | Root cause |
| --- | --- | --- | --- |
| Namespace discipline | 100% `bffi:` predicates/classes | Run-level predicates left as `bf:` | No remap step, only a type/URI split |
| Entity URIs | Consistent minted URIs | Work/Manifestation keep `id.loc.gov/resources/...`; only Expression is minted | `derive_wemi_from_loc` reuses LoC URIs (`Bibframe.pm:962-964`) |
| Work/Expression/Manifestation sub-classes | `MonographWork`, `MonographExpression`, `Text`, `Print` | Only the three base classes | No axis/type discrimination |
| Item | (pattern supports it) | Never emitted | No item pass |
| Identifiers | `bffi:identifiedBy` + `bffi:source` scheme / `bffi:qualifier` | Copied as-is if present | No identifier routing |
| Contributions/roles | `bffi:contribution` bnode, `bffi:agent`, `bffi:role`, `bffi:PrimaryContribution` | Depends on stored shape | No contribution node construction |
| Structured relations | `bffi:relation` + `bffi:relationship` + `bffi:associatedResource` | Copied as-is | No relation routing |
| AAP | `bffi:aap` on Work/Expression/Manifestation | Absent | Not generated |
| Provision activity | `bffi:provisionActivity` + `bffi:place`/`bffi:agent`/`bffi:simpleDate` | Copied as-is | No routing |
| Value vocabularies | MTS/YSO/Kauno/SLM URIs | LoC values where present | No authority/vocabulary resolution |
| Languages | Lexvo `lexvo:fin` | Whatever marc2bibframe2 emits | No language bridge |
| Administration | `bffi:adminMetadata` block with `encodingLevel`, `identifiedBy` | Absent | Not generated |

The single dominant cause is that the current export is a **rename of the
outer node types, not a projection of the graph through the BFFI ontology**.

## 4. Target projection design

The new projection replaces `derive_wemi_from_loc` for BFFI export:

```
stored LoC triples  ──┐
stored MARC (marc21) ─┤  BFFIProjector  ──> BFFI-only triples
rename/vocab config ──┘
```

Principles, informed by the National Library of Finland's
`bffi-conversion-pipeline` (MARCXML -> BIBFRAME -> BFFI -> MARCXML):

1. **Closed namespace.** The BFFI projection emits only `bffi:` classes and
   predicates. No `bf:` or `bflc:` term survives in the output.
2. **Ontology-driven rename.** The `bf:*`/`bflc:*` -> `bffi:*` table is
   *generated* from `config/lkd.rdf` (`owl:equivalentClass`,
   `owl:equivalentProperty`, `rdfs:subPropertyOf`), not hand-maintained.
3. **`bflc:marcKey` is the discriminator.** marc2bibframe2 emits the source
   MARC tag/indicators/subfields in `bflc:marcKey`; the projector forwards it as
   `bffi:marcKey` and uses it to route Hub, title variants, and series.
4. **Axis split by type.** `bf:instanceOf` / `bf:hasInstance` become the
   axis-specific `bffi:expressionManifested` / `bffi:workManifested` and
   `bffi:manifestationOfExpression` / `bffi:manifestationOfWork` based on
   whether the related node is Expression-typed.
5. **Deterministic URIs.** Entity URIs are minted deterministically per axis
   (hash of the source LoC URI, or the control number when available).
6. **Vocabularies from the ontology and CC0 bridges.** MTS/YSO/SLM and language
   bridges are derived from `lkd.ttl` and vendored bridges, with an optional
   Finto lookup hook (off by default).
7. **Validate by round-trip.** The projection is validated by projecting to
   BFFI, reconstructing MARC via `MarcGenerator`, and diffing by value against
   the stored MARC.
8. **No silent loss.** Terms that cannot be mapped are dropped visibly and
   counted, mirroring the pipeline's provenance and routing counters.

### Validation of the round-trip premise

`MarcGenerator` reads the stored MARC from
`record_format_mappings` where `format_name = 'marc21'`
(`Modules/MarcGenerator.pm:130`) and returns a `MARC::Record`. The same MARC is
what fed marc2bibframe2, so a BFFI -> MARC round-trip is a real fidelity signal,
not a synthetic one.

### Environment constraint

`RDF::Trine` and `Attean` are not installed in the target environment, so the
projection must not depend on a runtime RDF/SPARQL library. Parsing
`config/lkd.rdf` (RDF/XML) is done with `XML::LibXML`, the same parser already
used by `Bibframe::rdf_to_triples` (`Modules/Bibframe.pm:740`). The projection
operates on the plugin's existing triple representation
`{ subject, predicate, object, object_type }` with abbreviated predicates.

## 5. Lessons adopted from `bffi-conversion-pipeline`

| Lesson | Adopted here |
| --- | --- |
| Derive the rename from the ontology, not by hand | `tools/generate_bffi_rename.pl` reads `config/lkd.rdf` and emits `config/bffi_rename.yaml` |
| Closed namespace is a hard rule | `BFFIProjector` asserts no `bf:`/`bflc:` predicates remain |
| `bflc:marcKey` discriminates collapsed classes | Forwarded as `bffi:marcKey`; used for Hub/title/series routing |
| Axis split is type-driven | `instanceOf`/`hasInstance` to axis-specific predicates |
| Identifiers carry a scheme URI | `bffi:identifiedBy` + `bffi:source` |
| Relations are structured bnodes | `bffi:relation` + `bffi:relationship` + `bffi:associatedResource` |
| Value vocabularies come from the ontology | MTS links read from `lkd.ttl` `bffi-meta:relatedValueVocabulary` |
| Deterministic URI minting | Per-axis hash / control number |
| Validate by value-based MARC round-trip | BFFI -> MARC diff against stored MARC |
| Drop visibly, never silently | Routing counters surfaced as warnings |

Assets to vendor from the pipeline (CC0): `loc-languages-bridge.ttl`,
`loc-countries-bridge.ttl`, `loc-issuance-bridge.ttl`, `mts.ttl`.

## 6. Fidelity checklist

- [x] Output contains only `bffi:` and value-vocabulary (`mts:`, `yso:`,
  `kauno:`, `slm:`, `finaf:`, Lexvo) terms - no `bf:`/`bflc:`.
- [x] Work/Expression/Manifestation carry their sub-classes where derivable.
- [x] `bffi:aap` is present on Work, Expression, and Manifestation.
- [x] Identifiers are routed to `bffi:identifiedBy` with `bffi:source`.
- [x] Contributions are `bffi:Contribution` nodes with `bffi:agent`/`bffi:role`.
- [ ] `bf:hasSeries`/related resources appear as `bffi:relation` bnodes
  (generic `bf:relation`/`bf:associatedResource` forwarding is in place; the
  flattened source triples carry no series node to reify).
- [x] Entity URIs are minted consistently, not inherited from `id.loc.gov`.
- [ ] A BFFI -> MARC round-trip diff against stored MARC reports no fabricated
  values and no unexplained losses. Harness: `t/bffi_marc_roundtrip.t` skips
  unless given `BFFI_ROUNDTRIP_MARC` + `BFFI_ROUNDTRIP_RDF`, or
  `BFFI_ROUNDTRIP_DB=1` + `BFFI_ROUNDTRIP_BIBLIO`. (Not yet run against a real
  stored MARC, which needs the live store.)

## 7. References

- BFFI schema: <https://schema.finto.fi/bffi/> (1.0.0)
- Vendored ontology: `config/lkd.rdf`, `config/lkd.ttl`, `config/bibframe.rdf`
- Reference converter: <https://github.com/mikkovihonen/bffi-conversion-pipeline>
