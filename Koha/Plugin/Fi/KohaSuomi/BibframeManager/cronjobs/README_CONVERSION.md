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

A comprehensive script with many options for batch processing and different output formats.

**Usage:**
```bash
./convert_marc_to_Bibframe.pl [options]
```

**Options:**
- `--biblionumber=N` - Process specific biblionumber(s), comma-separated
- `--range=N-M` - Process a range of biblionumbers
- `--all` - Process all biblios in the database
- `--format=FORMAT` - Output format: turtle (default), json-ld, ntriples, rdfxml
- `--output=PATH` - Save to file instead of biblio_metadata table
- `--verbose` - Show detailed progress
- `--help` - Show help message

**Examples:**

Convert a single biblio:
```bash
./convert_marc_to_Bibframe.pl --biblionumber=123 --verbose
```

Convert multiple biblios:
```bash
./convert_marc_to_Bibframe.pl --biblionumber=123,124,125 --verbose
```

Convert a range of biblios:
```bash
./convert_marc_to_Bibframe.pl --range=100-200 --verbose
```

Convert all biblios to JSON-LD format:
```bash
./convert_marc_to_Bibframe.pl --all --format=json-ld --verbose
```

Export a single biblio to file:
```bash
./convert_marc_to_Bibframe.pl --biblionumber=123 --format=turtle --output=/tmp/biblio_123.ttl
```

Export multiple biblios to files:
```bash
./convert_marc_to_Bibframe.pl --range=100-105 --format=turtle --output=/tmp/biblio.ttl --verbose
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
