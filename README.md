
# Koha-Suomi Plugin: Bibframe Manager

Bibframe Manager is a Koha plugin for managing Bibframe (Finnish BIBFRAME) metadata. It converts MARC21 bibliographic records to Bibframe format, stores them in multiple RDF serialization formats, and provides tools for retrieval and export.

## Features

- Convert MARC21 records to Bibframe (Finnish BIBFRAME Implementation)
- Store Bibframe metadata in Koha's biblio_metadata table
- Support for multiple RDF formats: Turtle, JSON-LD, N-Triples, RDF/XML
- Batch conversion scripts
- Export capabilities
- Full lifecycle management: create, read, update, delete

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

# Usage

## Converting Records

Two scripts are provided in the `cronjobs/` directory:

### Simple Conversion (single record)
```bash
./Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/simple_marc_to_Bibframe.pl 123
```

### Batch Conversion

`convert_marc_to_Bibframe.pl` fetches MARC21 records from the database and
converts them to BIBFRAME. It supports two conversion engines, selected with
`--engine`:

- `--engine=xslt` (default) - Runs the official
  [marc2bibframe2](https://github.com/lcnetdev/marc2bibframe2) XSLT converter
  (bundled in `config/`) over all selected records in one pass and writes a
  single RDF/XML file.
- `--engine=plugin` - Uses the plugin's own Bibframe module (Finnish BIBFRAME
  Implementation) and stores the result in the `biblio_metadata` table or in
  per-record files.

```bash
cd Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/

# Convert a single record to a single RDF/XML file (xslt engine)
perl convert_marc_to_Bibframe.pl --biblionumber=123 --output=123.rdf

# Convert a range of records with a custom URI stem
perl convert_marc_to_Bibframe.pl --range=1-100 --baseuri=http://mylibrary.org/

# Multiple / file selection
perl convert_marc_to_Bibframe.pl --biblionumber=123,124,125
perl convert_marc_to_Bibframe.pl --file=numbers.txt

# All records
perl convert_marc_to_Bibframe.pl --all --output=all-biblios.rdf

# Plugin engine: convert all biblios to JSON-LD, stored in the database
perl convert_marc_to_Bibframe.pl --all --engine=plugin --format=json-ld --verbose
```

**Selection options** (both engines):
- `--biblionumber=N` / `--biblionumbers=N,M,...` - One or more records, comma-separated
- `--file=FILE` - Records listed in FILE (one biblionumber per line)
- `--range=N-M` - A range of biblionumbers (inclusive)
- `--start=N --end=M` - Same as `--range`
- `--all` - All records
- `--limit=N` / `--offset=N` - Only convert up to N records, skipping the first N

**xslt engine options:**
- `--output=FILE` - Output RDF/XML file (default: `bibframe.rdf`)
- `--xsl=PATH` - Path to `marc2bibframe2.xsl` (defaults to the copy bundled in `config/`)
- `--baseuri=URI` - URI stem used for minting entity URIs (default: `http://example.org/`)
- `--idsource=URI` - URI identifying the source of the record IDs
- `--keep-marcxml=FILE` - Also save the generated MARCXML collection for debugging

**plugin engine options:**
- `--format=FORMAT` - turtle (default), json-ld, ntriples, rdfxml, json
- `--output=PATH` - Save to file(s) instead of the `biblio_metadata` table (a
  biblionumber suffix is appended when multiple records are selected)
- `--dry-run` - Don't save anything

Both engines support `--verbose` and `--help`. Requirements: `xsltproc` and
`XML::LibXML` (xslt engine), plus a Koha environment for the database access.

See `Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/README_CONVERSION.md` for detailed documentation.

# Configuration

No special configuration is required. The plugin uses Koha's standard `biblio_metadata` table for storage.

