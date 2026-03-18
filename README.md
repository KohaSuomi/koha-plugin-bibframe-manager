
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
```bash
# Single biblionumber
./Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/convert_marc_to_Bibframe.pl --biblionumber=123 --verbose

# Multiple biblionumbers
./Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/convert_marc_to_Bibframe.pl --biblionumber=123,124,125 --verbose

# Range of biblionumbers
./Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/convert_marc_to_Bibframe.pl --range=100-200 --verbose

# All biblios
./Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/convert_marc_to_Bibframe.pl --all --format=json-ld --verbose
```

See `Koha/Plugin/Fi/KohaSuomi/BibframeManager/cronjobs/README_CONVERSION.md` for detailed documentation.

# Configuration

No special configuration is required. The plugin uses Koha's standard `biblio_metadata` table for storage.

