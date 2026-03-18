#!/usr/bin/perl

# Script to fetch MARC21 records from biblio_metadata and convert to Bibframe
#
# Usage:
#   ./convert_marc_to_Bibframe.pl --biblionumber=123
#   ./convert_marc_to_Bibframe.pl --biblionumber=123,124,125
#   ./convert_marc_to_Bibframe.pl --range=100-200
#   ./convert_marc_to_Bibframe.pl --all
#   ./convert_marc_to_Bibframe.pl --biblionumber=123 --format=turtle --output=/tmp/output.ttl
#
# Options:
#   --biblionumber=N    Process specific biblionumber(s), comma-separated
#   --range=N-M         Process range of biblionumbers
#   --all               Process all biblios in database
#   --format=FORMAT     Output format: turtle (default), json-ld, ntriples, rdfxml
#   --output=PATH       Save to file instead of biblio_metadata table
#   --verbose           Show detailed progress
#   --help              Show this help

use Modern::Perl;
use Getopt::Long;
use Pod::Usage;
use MARC::Record;
use MARC::File::XML (BinaryEncoding => 'utf8');
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use C4::Context;
use C4::Biblio;

# Parse command line options
my $biblionumber_str;
my $range;
my $all;
my $format = 'turtle';
my $output_file;
my $verbose;
my $help;

GetOptions(
    'biblionumber=s' => \$biblionumber_str,
    'range=s'        => \$range,
    'all'            => \$all,
    'format=s'       => \$format,
    'output=s'       => \$output_file,
    'verbose'        => \$verbose,
    'help|?'         => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

# Validate format
my %valid_formats = (
    'turtle'    => 1,
    'json-ld'   => 1,
    'ntriples'  => 1,
    'rdfxml'    => 1,
    'json'      => 1,
);

unless ($valid_formats{$format}) {
    die "Invalid format: $format. Valid formats are: " . join(', ', sort keys %valid_formats) . "\n";
}

# Determine which biblionumbers to process
my @biblionumbers;

if ($biblionumber_str) {
    @biblionumbers = split(/,/, $biblionumber_str);
} elsif ($range) {
    if ($range =~ /^(\d+)-(\d+)$/) {
        my ($start, $end) = ($1, $2);
        @biblionumbers = ($start .. $end);
    } else {
        die "Invalid range format. Use: --range=100-200\n";
    }
} elsif ($all) {
    @biblionumbers = get_all_biblionumbers();
} else {
    pod2usage("Error: You must specify --biblionumber, --range, or --all\n");
}

unless (@biblionumbers) {
    die "No biblionumbers to process\n";
}

# Process biblionumbers
my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();

my $total = scalar @biblionumbers;
my $processed = 0;
my $errors = 0;
my $skipped = 0;

say "Processing $total biblionumber(s)..." if $verbose;
say "Output format: $format" if $verbose;
say "Output file: $output_file" if $output_file && $verbose;
say "";

foreach my $biblionumber (@biblionumbers) {
    eval {
        # Fetch MARC21 record from biblio_metadata
        say "Processing biblionumber $biblionumber..." if $verbose;
        
        my $marc_record = Koha::Biblios->find($biblionumber)->metadata->record;
        
        unless ($marc_record) {
            warn "  Warning: No MARC21 record found for biblionumber $biblionumber\n";
            $skipped++;
            return;
        }
        
        # Convert to Bibframe
        say "  Converting to Bibframe..." if $verbose;
        my $triples = $converter->convert_record_to_Bibframe(
            $marc_record,
            base_uri => "http://urn.fi/URN:NBN:fi:bib:$biblionumber"
        );
        
        unless ($triples && @$triples) {
            warn "  Warning: Conversion produced no triples for biblionumber $biblionumber\n";
            $skipped++;
            return;
        }
        
        say "  Generated " . scalar(@$triples) . " triples" if $verbose;
        
        # Save the converted record
        if ($output_file) {
            # Save to file
            save_to_file($biblionumber, $triples, $format, $output_file);
        } else {
            # Save to biblio_metadata table
            say "  Saving to biblio_metadata table..." if $verbose;
            my $id = $db->saveBibframeMetadata(
                $biblionumber,
                $triples,
                format => $format,
                schema => 'Bibframe'
            );
            say "  Saved with metadata ID: $id" if $verbose;
        }
        
        $processed++;
        say "  Success!\n" if $verbose;
    };
    
    if ($@) {
        warn "Error processing biblionumber $biblionumber: $@\n";
        $errors++;
    }
}

# Print summary
say "=" x 60;
say "Conversion Summary:";
say "  Total biblionumbers: $total";
say "  Successfully processed: $processed";
say "  Skipped (no record): $skipped";
say "  Errors: $errors";
say "=" x 60;

exit($errors > 0 ? 1 : 0);

#
# Subroutines
#

=head2 fetch_marc_record

Fetches MARC21 record from biblio_metadata table

=cut

sub fetch_marc_record {
    my ($biblionumber) = @_;
    
    # Use Koha's standard method to get MARC record
    my $marc_record = GetMarcBiblio({ 
        biblionumber => $biblionumber,
        embed_items  => 0 
    });
    
    return $marc_record;
}

=head2 get_all_biblionumbers

Gets all biblionumbers from the database

=cut

sub get_all_biblionumbers {
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare(
        "SELECT DISTINCT biblionumber FROM biblio_metadata 
         WHERE format = 'marcxml' AND schema = 'MARC21'
         ORDER BY biblionumber"
    );
    $sth->execute();
    
    my @biblionumbers;
    while (my $row = $sth->fetchrow_hashref()) {
        push @biblionumbers, $row->{biblionumber};
    }
    
    return @biblionumbers;
}

=head2 save_to_file

Saves converted Bibframe data to a file

=cut

sub save_to_file {
    my ($biblionumber, $triples, $format, $output_file) = @_;
    
    my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
    my $serialized = $db->serializeTriples($triples, $format);
    
    # Determine file extension
    my %extensions = (
        'turtle'   => '.ttl',
        'json-ld'  => '.jsonld',
        'ntriples' => '.nt',
        'rdfxml'   => '.rdf',
        'json'     => '.json',
    );
    
    # If processing multiple biblios, append biblionumber to filename
    my $filename = $output_file;
    if (scalar @biblionumbers > 1) {
        # Insert biblionumber before extension
        my $ext = $extensions{$format} || ".$format";
        $filename =~ s/(\.[^.]+)?$/_$biblionumber$ext/;
    }
    
    open my $fh, '>:encoding(UTF-8)', $filename
        or die "Cannot open $filename for writing: $!";
    print $fh $serialized;
    close $fh;
    
    say "  Saved to file: $filename" if $verbose;
}

__END__

=head1 NAME

convert_marc_to_Bibframe.pl - Convert MARC21 records to Bibframe (Bibframe Finland Implementation)

=head1 SYNOPSIS

convert_marc_to_Bibframe.pl [options]

 Options:
   --biblionumber=N    Process specific biblionumber(s), comma-separated
   --range=N-M         Process range of biblionumbers
   --all               Process all biblios in database
   --format=FORMAT     Output format: turtle (default), json-ld, ntriples, rdfxml
   --output=PATH       Save to file instead of biblio_metadata table
   --verbose           Show detailed progress
   --help              Show this help message

=head1 DESCRIPTION

This script fetches MARC21 records from the biblio_metadata table,
converts them to Bibframe (Bibframe Finland Implementation) format using
RDF triples, and saves the converted records either back to the
biblio_metadata table or to a file.

=head1 EXAMPLES

Convert a single biblio to Bibframe and save to database:

  ./convert_marc_to_Bibframe.pl --biblionumber=123 --verbose

Convert multiple biblios:

  ./convert_marc_to_Bibframe.pl --biblionumber=123,124,125 --verbose

Convert a range of biblios:

  ./convert_marc_to_Bibframe.pl --range=100-200 --verbose

Convert all biblios to JSON-LD format:

  ./convert_marc_to_Bibframe.pl --all --format=json-ld --verbose

Export single biblio to Turtle file:

  ./convert_marc_to_Bibframe.pl --biblionumber=123 --format=turtle --output=/tmp/biblio_123.ttl

=head1 SUPPORTED FORMATS

=over 4

=item * turtle - Turtle/TTL format (default, most readable for humans)

=item * json-ld - JSON-LD format (best for APIs and web services)

=item * ntriples - N-Triples format (simplest, good for bulk processing)

=item * rdfxml - RDF/XML format (traditional RDF format)

=item * json - Simple JSON array of triples

=back

=head1 DATABASE STORAGE

When saving to the database (no --output specified), the converted Bibframe
records are stored in the biblio_metadata table with:
  - format: The specified format (turtle, json-ld, etc.)
  - schema: 'Bibframe'
  - metadata: The serialized RDF triples

Benefits of using biblio_metadata:
  - Automatic CASCADE delete when biblio is deleted
  - Native Koha integration
  - Support for multiple formats simultaneously
  - Timestamp tracking

=head1 AUTHOR

Koha-Suomi Oy

=head1 LICENSE

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

=cut
