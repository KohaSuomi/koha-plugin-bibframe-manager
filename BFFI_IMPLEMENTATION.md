# BFFI (Finnish BIBFRAME) Implementation

## Overview

This implementation integrates the **LKD (Linkitetyn kirjastodatan tietomalli)** - Finnish BIBFRAME data model into the RDF Triple plugin. The BFFI model is based on BIBFRAME 2.4.0 and extends it with RDA elements and Finnish cataloging requirements.

## Key Features

### Data Model Structure

The BFFI implementation follows the RDA-compliant four-level structure:

1. **Work** (`bffi:Work`) - Abstract intellectual or artistic creation
2. **Expression** (`bffi:Expression`) - Specific realization of a work (e.g., a particular edition, translation)
3. **Manifestation** (`bffi:Manifestation`) - Physical embodiment (equivalent to BIBFRAME Instance)
4. **Item** (`bffi:Item`) - Single example of a manifestation

This differs from standard BIBFRAME which combines Work and Expression into a single Work level.

### Namespaces

The implementation supports multiple namespaces:

- `bffi:` - http://urn.fi/URN:NBN:fi:schema:bffi: (Finnish BIBFRAME)
- `bf:` - http://id.loc.gov/ontologies/bibframe/ (BIBFRAME)
- `rdaw:` - http://rdaregistry.info/Elements/w/ (RDA Work elements)
- `rdae:` - http://rdaregistry.info/Elements/e/ (RDA Expression elements)
- `rdam:` - http://rdaregistry.info/Elements/m/ (RDA Manifestation elements)
- `rdai:` - http://rdaregistry.info/Elements/i/ (RDA Item elements)

### MARC21 Field Mappings

#### Work Level Fields
Fields that describe the abstract intellectual content:
- 100, 110, 111 - Creators
- 130, 240 - Uniform titles
- 380 - Form of work
- 382 - Medium of performance
- 383-386 - Work characteristics
- 600-655 - Subject headings

#### Expression Level Fields
Fields that describe the specific realization:
- 041, 377 - Language information
- 130, 240, 245 - Title information
- 250 - Edition statement
- 336 - Content type
- 340 - Technical details
- 500-546 - Notes
- 700, 710, 711 - Contributors

#### Manifestation Level Fields
Fields that describe the physical embodiment:
- 001, 003 - Control numbers
- 015, 020, 022, 024, 028 - Identifiers
- 260, 264 - Publication information
- 300 - Physical description
- 337, 338 - Media and carrier types
- 340 - Physical characteristics
- 490 - Series information
- 775, 776 - Related manifestations
- 856 - Electronic location

#### Item Level Fields
Fields that describe individual copies:
- 852 - Location
- 866 - Holdings
- 876 - Item information

## Usage

### Basic BFFI Conversion

```perl
use Koha::Plugin::Fi::KohaSuomi::BFFIManager::Modules::Bibframe;
use MARC::Record;

# Create a Bibframe converter instance
my $converter = Koha::Plugin::Fi::KohaSuomi::BFFIManager::Modules::Bibframe->new();

# Load your MARC record
my $marc_record = MARC::Record->new();
# ... populate the record ...

# Convert to BFFI triples
my $triples = $converter->convert_record_to_bffi($marc_record);

# Process the triples
foreach my $triple (@$triples) {
    print "Subject: $triple->{subject}\n";
    print "Predicate: $triple->{predicate}\n";
    print "Object: $triple->{object}\n";
    print "Object Type: $triple->{object_type}\n";
    print "---\n";
}
```

### Custom Base URI

```perl
# Use a custom base URI for generated URIs
my $triples = $converter->convert_record_to_bffi(
    $marc_record,
    base_uri => 'http://data.kirjastot.fi/'
);
```

### Legacy BIBFRAME Conversion

The original BIBFRAME conversion method is still available:

```perl
# Convert using standard BIBFRAME (Work/Instance model)
my $triples = $converter->convert_record_to_bibframe($marc_record);
```

## Key Relationships

The BFFI model uses the following key relationships to connect the levels:

- **Work → Expression**: `bffi:hasExpression` / `bffi:expressionOf`
- **Expression → Manifestation**: `bffi:manifestationOfExpression` / `bffi:expressionManifested`
- **Manifestation → Item**: `bffi:hasItem` / `bffi:itemOf`
- **Work → Creator**: `bffi:creator`
- **Expression → Contributor**: `bffi:contributor`

## RDF Triple Structure

Each triple generated contains:

```perl
{
    subject     => 'URI of the subject resource',
    predicate   => 'Property connecting subject to object',
    object      => 'Value or URI of the object',
    object_type => 'literal' or 'uri'
}
```

## Example Output

For a MARC record with control number `001234567`, the converter generates:

```turtle
# Work level
<http://urn.fi/URN:NBN:fi:bib:work/001234567> a bffi:Work ;
    bffi:creator <http://urn.fi/URN:NBN:fi:bib:agent/Virtanen_Matti> ;
    bffi:subject "Library science" .

# Expression level
<http://urn.fi/URN:NBN:fi:bib:expression/001234567> a bffi:Expression ;
    bffi:expressionOf <http://urn.fi/URN:NBN:fi:bib:work/001234567> ;
    bffi:title "Kirjastotiede" ;
    bffi:language "fin" .

# Manifestation level
<http://urn.fi/URN:NBN:fi:bib:manifestation/001234567> a bffi:Manifestation ;
    bffi:expressionManifested <http://urn.fi/URN:NBN:fi:bib:expression/001234567> ;
    bffi:isbn "978-951-0-12345-6" ;
    bffi:extent "256 sivua" .

# Agent
<http://urn.fi/URN:NBN:fi:bib:agent/Virtanen_Matti> a bf:Person ;
    rdfs:label "Virtanen, Matti" .
```

## BFFI Schema Source

The implementation is based on the official BFFI schema:
- Schema page: https://schema.finto.fi/bffi/
- Version: 1.0.0 (2025-01-02)
- Turtle format: https://schema.finto.fi/bffi/lkd.ttl
- Publisher: National Library of Finland (Kansalliskirjasto)

## References

- [BIBFRAME 2.4.0 Specification](https://id.loc.gov/ontologies/bibframe-2-4-0.html)
- [RDA Registry](https://www.rdaregistry.info/)
- [BFFI Schema Documentation](https://schema.finto.fi/bffi/)
- [Finnish Cataloging Guidelines](https://kansalliskirjasto.finna.fi/)

## License

This implementation follows the license of the parent plugin. The BFFI schema itself is licensed under CC0 1.0 Universal.

## Contributors

- Based on BFFI schema by Linkitetty kirjastodata -projekti
- Implementation: Koha-Suomi Oy

## Author

Johanna Räisä <johanna.raisa@koha-suomi.fi>
Assisted by: Claude Sonnet 4.5
