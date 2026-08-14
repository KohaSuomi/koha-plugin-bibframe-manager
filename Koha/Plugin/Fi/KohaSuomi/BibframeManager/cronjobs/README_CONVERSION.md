# MARC21 to Bibframe Conversion Scripts

This directory contains scripts for converting MARC21 records to Bibframe (Bibframe Finland Implementation) format.

## Scripts

### 1. simple_marc_to_Bibframe.pl

A simple, educational script that demonstrates the complete workflow of converting a single MARC21 record to Bibframe.

**Usage:**
```bash
./simple_marc_to_Bibframe.pl <biblionumber>
```

**Example:**
```bash
./simple_marc_to_Bibframe.pl 123
```

**What it does:**
1. Fetches MARC21 record from biblio_metadata table for the specified biblionumber
2. Converts it to Bibframe (Bibframe Finland Implementation) using RDF triples
3. Saves the converted record to biblio_metadata table in three formats:
   - Turtle (most readable for humans)
   - JSON-LD (best for APIs)
   - N-Triples (simple format for bulk processing)
4. Exports the Turtle format to `/tmp/biblio_<biblionumber>_Bibframe.ttl`
5. Displays a summary with sample triples

**Output:**
- Database records in `biblio_metadata` table with schema='Bibframe'
- Export file in /tmp directory

---

### 2. convert_marc_to_Bibframe.pl

A comprehensive script with many options for batch processing, two conversion
engines, and different output formats.

**Usage:**
```bash
./convert_marc_to_Bibframe.pl [options]
```

**Conversion engines (--engine):**
- `xslt` (default) - Runs the official [marc2bibframe2](https://github.com/lcnetdev/marc2bibframe2)
  XSLT converter (bundled in `config/`) over all selected records in one pass
  and writes a single RDF/XML file.
- `plugin` - Uses the plugin's own Bibframe module (Finnish BIBFRAME
  Implementation) and stores the result in the `biblio_metadata` table or in
  per-record files.

**Options:**
- `--engine=ENGINE` - Conversion engine: `xslt` (default) or `plugin`
- `--biblionumber=N` - Process specific biblionumber(s), comma-separated
- `--biblionumbers=N,M,...` - Same as `--biblionumber`
- `--file=FILE` - Process records listed in FILE (one biblionumber per line)
- `--range=N-M` - Process a range of biblionumbers
- `--start=N` / `--end=M` - Same as `--range`
- `--all` - Process all biblios in the database
- `--limit=N` / `--offset=N` - Only process up to N records, skipping the first N
- `--format=FORMAT` - Plugin engine only: turtle (default), json-ld, ntriples, rdfxml, json
- `--output=PATH` - xslt engine: the single RDF/XML output file. plugin engine: save to file(s) instead of the biblio_metadata table
- `--xsl=PATH` - xslt engine only: path to `marc2bibframe2.xsl` (defaults to the copy bundled in `config/`)
- `--baseuri=URI` - xslt engine only: URI stem used for minting entity URIs
- `--idsource=URI` - xslt engine only: URI identifying the source of the record IDs
- `--keep-marcxml=FILE` - xslt engine only: also save the generated MARCXML collection
- `--dry-run` - Don't save/write anything
- `--verbose` - Show detailed progress
- `--help` - Show help message

**Examples:**

Convert a single biblio to a single RDF/XML file (xslt engine, default):
```bash
./convert_marc_to_Bibframe.pl --biblionumber=123 --output=123.rdf --verbose
```

Convert multiple biblios:
```bash
./convert_marc_to_Bibframe.pl --biblionumber=123,124,125 --verbose
```

Convert a range of biblios with a custom URI stem:
```bash
./convert_marc_to_Bibframe.pl --range=100-200 --baseuri=http://mylibrary.org/ --verbose
```

Convert all biblios to JSON-LD format and store in the database (plugin engine):
```bash
./convert_marc_to_Bibframe.pl --all --engine=plugin --format=json-ld --verbose
```

Export a single biblio to a Turtle file (plugin engine):
```bash
./convert_marc_to_Bibframe.pl --biblionumber=123 --engine=plugin --format=turtle --output=/tmp/biblio_123.ttl
```

Export multiple biblios to files (plugin engine):
```bash
./convert_marc_to_Bibframe.pl --range=100-105 --engine=plugin --format=turtle --output=/tmp/biblio.ttl --verbose
```
(This will create separate files: biblio_100.ttl, biblio_101.ttl, etc.)

---

## Supported Output Formats

| Format | Extension | Description | Best For |
|--------|-----------|-------------|----------|
| turtle | .ttl | Turtle/TTL format | Human readability, debugging |
| json-ld | .jsonld | JSON-LD format | APIs, web services |
| ntriples | .nt | N-Triples format | Bulk processing, simple parsing |
| rdfxml | .rdf | RDF/XML format | Traditional RDF applications |
| json | .json | Simple JSON array | Simple data interchange |

---

## Database Storage

When saving to the database (default behavior, no `--output` specified), the converted Bibframe records are stored in the `biblio_metadata` table with:

- **biblionumber**: The biblionumber being described
- **format**: The serialization format (turtle, json-ld, etc.)
- **schema**: Always 'Bibframe' for these conversions
- **metadata**: The serialized RDF triples
- **timestamp**: Automatically updated on save

**Benefits of using biblio_metadata table:**
- Automatic CASCADE delete when biblio is deleted
- Native Koha integration
- Support for multiple formats simultaneously
- Automatic timestamp tracking
- No custom tables to maintain

**Example query:**
```sql
SELECT * FROM biblio_metadata 
WHERE biblionumber = 123 
  AND schema = 'Bibframe';
```

---

## How It Works

### 1. Fetching MARC21 Records

The scripts use Koha's standard `C4::Biblio::GetMarcBiblio()` function to fetch MARC21 records from the `biblio_metadata` table:

```perl
my $marc_record = C4::Biblio::GetMarcBiblio({ 
    biblionumber => $biblionumber,
    embed_items  => 0 
});
```

### 2. Converting to Bibframe

The conversion is performed by `Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe`:

```perl
my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
my $triples = $converter->convert_record_to_Bibframe(
    $marc_record,
    base_uri => "http://urn.fi/URN:NBN:fi:bib:$biblionumber"
);
```

This produces an array of RDF triples (subject, predicate, object) following the Bibframe standard.

### 3. Saving the Converted Record

The `Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database` module handles saving:

```perl
my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
my $id = $db->saveBibframeMetadata(
    $biblionumber,
    $triples,
    format => 'turtle',
    schema => 'Bibframe'
);
```

---

## Requirements

- Koha ILS installation
- koha-plugin-rdf-triple plugin installed
- Perl modules:
  - Modern::Perl
  - MARC::Record
  - C4::Context
  - C4::Biblio
  - Getopt::Long (for convert_marc_to_Bibframe.pl)

---

## Troubleshooting

**Error: "No MARC21 record found for biblionumber X"**
- The biblionumber doesn't exist or has no MARC21 metadata
- Check: `SELECT * FROM biblio_metadata WHERE biblionumber = X AND format = 'marcxml'`

**Error: "Conversion produced no triples"**
- The MARC record may be empty or malformed
- Check the MARC record structure

**Permission denied**
- Make sure the scripts are executable: `chmod +x *.pl`
- Ensure you have write permissions for output directory

**Database connection errors**
- Ensure Koha environment variables are set
- Run scripts in the Koha shell: `koha-shell <instance> -c "./script.pl ..."`

---

## See Also

- [USAGE_EXAMPLE.pl](USAGE_EXAMPLE.pl) - Additional code examples
- [Bibframe_IMPLEMENTATION.md](../../Bibframe_IMPLEMENTATION.md) - Bibframe specification
- Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe - Conversion module
- Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database - Database module

---

## License

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
