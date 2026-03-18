#!/usr/bin/perl

# Simple script to convert a single MARC21 record to Bibframe
#
# Usage: ./simple_marc_to_Bibframe.pl <biblionumber>
#
# This script:
# 1. Fetches MARC21 record from biblio_metadata table
# 2. Converts it to Bibframe (Bibframe Finland Implementation) 
# 3. Saves the converted record to biblio_metadata table
# 4. Optionally exports to a file

use Modern::Perl;
use MARC::Record;
use C4::Context;
use C4::Biblio;
use Koha::Biblios;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;

# Get biblionumber from command line
my $biblionumber = shift @ARGV;

unless ($biblionumber && $biblionumber =~ /^\d+$/) {
    die "Usage: $0 <biblionumber>\n";
}

say "=" x 60;
say "MARC21 to Bibframe Converter";
say "=" x 60;
say "";

# Step 1: Fetch MARC21 record from biblio_metadata table
say "Step 1: Fetching MARC21 record for biblionumber $biblionumber...";

my $marc_record = Koha::Biblios->find($biblionumber)->metadata->record;

unless ($marc_record) {
    die "ERROR: No MARC21 record found for biblionumber $biblionumber\n";
}

my $title = $marc_record->title() || 'Unknown Title';
say "  Found record: $title";
say "";

# Step 2: Convert to Bibframe
say "Step 2: Converting to Bibframe format...";

my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();

my $triples = $converter->convert_record_to_Bibframe(
    $marc_record,
    base_uri => "http://urn.fi/URN:NBN:fi:bib:$biblionumber"
);

unless ($triples && @$triples) {
    die "ERROR: Conversion produced no triples\n";
}

say "  Generated " . scalar(@$triples) . " RDF triples";
say "";

# Display a few sample triples
say "Sample triples:";
my $sample_count = ($#$triples < 4) ? $#$triples : 4;
for my $i (0..$sample_count) {
    my $t = $triples->[$i];
    say "  $t->{subject} -> $t->{predicate} -> $t->{object}";
}
say "  ..." if @$triples > 5;
say "";

# Step 3: Save to biblio_metadata table
say "Step 3: Saving converted record to biblio_metadata table...";

my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();

# Save in Turtle format (most readable)
my $turtle_id = $db->saveBibframeMetadata(
    $biblionumber,
    $triples,
    format => 'turtle',
    schema => 'Bibframe'
);
say "  Saved as Turtle format (metadata ID: $turtle_id)";

# Save in JSON-LD format (good for APIs)
my $jsonld_id = $db->saveBibframeMetadata(
    $biblionumber,
    $triples,
    format => 'json-ld',
    schema => 'Bibframe'
);
say "  Saved as JSON-LD format (metadata ID: $jsonld_id)";

# Save in N-Triples format (simple)
my $ntriples_id = $db->saveBibframeMetadata(
    $biblionumber,
    $triples,
    format => 'ntriples',
    schema => 'Bibframe'
);
say "  Saved as N-Triples format (metadata ID: $ntriples_id)";
say "";

# Step 4: Export to file (optional)
my $export_file = "/tmp/biblio_${biblionumber}_Bibframe.ttl";
say "Step 4: Exporting to file: $export_file";

my $metadata = $db->getBibframeMetadata($biblionumber, 'turtle', 'Bibframe');

if ($metadata) {
    open my $fh, '>:encoding(UTF-8)', $export_file
        or die "Cannot open $export_file for writing: $!";
    print $fh $metadata->{metadata};
    close $fh;
    say "  Export successful!";
} else {
    warn "  WARNING: Could not retrieve metadata for export\n";
}

say "";
say "=" x 60;
say "Conversion Complete!";
say "=" x 60;
say "";
say "Summary:";
say "  Biblionumber: $biblionumber";
say "  Title: $title";
say "  Triples generated: " . scalar(@$triples);
say "  Formats saved: Turtle, JSON-LD, N-Triples";
say "  Exported to: $export_file";
say "";
say "To retrieve the metadata from database:";
say "  SELECT * FROM biblio_metadata WHERE biblionumber = $biblionumber AND schema = 'Bibframe';";
say "";

# Show database query example
say "Database records created:";
my $all_metadata = $db->getAllBibframeMetadata($biblionumber);
foreach my $meta (@$all_metadata) {
    my $size = length($meta->{metadata});
    say "  ID: $meta->{id}, Format: $meta->{format}, Schema: $meta->{schema}, Size: $size bytes";
}

say "";
say "Done!";

__END__

=head1 NAME

simple_marc_to_Bibframe.pl - Simple MARC21 to Bibframe converter

=head1 SYNOPSIS

  ./simple_marc_to_Bibframe.pl <biblionumber>

=head1 DESCRIPTION

This is a simple, educational script that demonstrates the complete workflow
of converting a MARC21 record to Bibframe (Bibframe Finland Implementation) format.

The script performs these steps:
  1. Fetches MARC21 record from biblio_metadata table
  2. Converts it to Bibframe using RDF triples
  3. Saves to biblio_metadata in multiple formats
  4. Exports to a file in /tmp

=head1 EXAMPLE

  ./simple_marc_to_Bibframe.pl 123

This will:
  - Convert biblionumber 123 to Bibframe
  - Save as Turtle, JSON-LD, and N-Triples in biblio_metadata
  - Export Turtle format to /tmp/biblio_123_Bibframe.ttl

=cut
