#!/usr/bin/perl

# Copyright 2026 KohaSuomi
#
# This script fetches MARC21 records from the Koha database and converts
# them to BIBFRAME. Two conversion engines are available:
#
#   --engine=xslt   (default) Runs the marc2bibframe2 XSLT converter
#                   (https://github.com/lcnetdev/marc2bibframe2) over a
#                   marc:collection of records in one pass and writes a
#                   single RDF/XML output file.
#
#   --engine=plugin Uses the plugin's own Bibframe conversion module
#                   (Finnish BIBFRAME Implementation) and stores the result
#                   in the biblio_metadata table or in per-record files.

use Modern::Perl;
use Getopt::Long qw(GetOptions);
use Pod::Usage;
use FindBin qw($Bin);
use C4::Context;
use MARC::Record;
use MARC::File::XML (BinaryEncoding => 'utf8');
use Koha::Biblios;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use XML::LibXML;
use Encode qw(encode_utf8);
use File::Temp qw(tempfile);

# Path to the marc2bibframe2 stylesheet bundled with this plugin -
# adjust or override with --xsl
my $DEFAULT_XSL = "$Bin/../config/marc2bibframe2.xsl";

# Options
my $biblionumber_str;
my $from_file;
my $range;
my $start;
my $end;
my $all = 0;
my $limit;
my $offset;
my $engine = 'xslt';
my $format = 'turtle';
my $output_file;
my $xsl = $DEFAULT_XSL;
my $baseuri = 'http://example.org/';
my $idsource;
my $keep_marcxml;
my $dry_run;
my $verbose;
my $help;

GetOptions(
    'biblionumber=s'  => \$biblionumber_str,
    'biblionumbers=s'  => \$biblionumber_str,
    'file=s'           => \$from_file,
    'range=s'          => \$range,
    'start=i'          => \$start,
    'end=i'            => \$end,
    'all'              => \$all,
    'limit=i'          => \$limit,
    'offset=i'         => \$offset,
    'engine=s'         => \$engine,
    'format=s'         => \$format,
    'output=s'         => \$output_file,
    'xsl=s'            => \$xsl,
    'baseuri=s'        => \$baseuri,
    'idsource=s'       => \$idsource,
    'keep-marcxml=s'   => \$keep_marcxml,
    'dry-run'          => \$dry_run,
    'verbose'          => \$verbose,
    'help|?'           => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

# Validate engine
$engine = lc $engine;
my %valid_engines = ( 'xslt' => 1, 'plugin' => 1 );
unless ($valid_engines{$engine}) {
    die "Invalid engine: $engine. Valid engines are: xslt, plugin\n";
}

# Validate format (plugin engine only)
my %valid_formats = (
    'turtle'   => 1,
    'json-ld'  => 1,
    'ntriples' => 1,
    'rdfxml'   => 1,
    'json'     => 1,
);
unless ($valid_formats{$format}) {
    die "Invalid format: $format. Valid formats are: " . join(', ', sort keys %valid_formats) . "\n";
}

if ($engine eq 'xslt' && $format ne 'turtle') {
    warn "Warning: --format is ignored by the xslt engine (output is always RDF/XML)\n";
}

# Resolve record selection into an SQL condition
my @biblionumbers;
if ($biblionumber_str) {
    @biblionumbers = grep { length } split(/,/, $biblionumber_str);
} elsif (defined $from_file) {
    die "--file $from_file not found\n" unless -f $from_file;
    open my $fh, '<', $from_file or die "Cannot open $from_file: $!\n";
    @biblionumbers = grep { /^\d+$/ } map { s/\s+//gr } <$fh>;
    close $fh;
    die "No biblionumbers found in $from_file\n" unless @biblionumbers;
} elsif (defined $range && $range =~ /^(\d+)-(\d+)$/) {
    $start = $1;
    $end   = $2;
}

my @selectors;
if (@biblionumbers) {
    my $placeholders = join ',', ('?') x @biblionumbers;
    @selectors = ("biblionumber IN ($placeholders)", @biblionumbers);
} elsif (defined $start && defined $end) {
    die "--end must be >= --start\n" if $end < $start;
    @selectors = ("biblionumber BETWEEN ? AND ?", $start, $end);
} elsif (defined $start) {
    @selectors = ("biblionumber >= ?", $start);
} elsif (defined $end) {
    @selectors = ("biblionumber <= ?", $end);
} elsif ($all) {
    # no additional condition
} else {
    pod2usage("Error: You must specify --biblionumber, --biblionumbers, --file, --range, --start/--end, or --all\n");
}

if ($engine eq 'xslt') {
    die "xsltproc not found in PATH - please install xsltproc\n"
        unless system('which', 'xsltproc') == 0;
    die "Stylesheet not found: $xsl\n" unless -f $xsl;
}

# Fetch the selected records from biblio_metadata
my $dbh = C4::Context->dbh;

my $sql = "SELECT biblionumber, metadata FROM biblio_metadata WHERE format = 'marcxml'";
$sql .= ' AND ' . shift @selectors if @selectors;
$sql .= " ORDER BY biblionumber";
$sql .= " LIMIT $limit" if defined $limit;
if (defined $offset) {
    die "--offset requires --limit\n" unless defined $limit;
    $sql .= " OFFSET $offset";
}

print "SQL: $sql\n" if $verbose;

my $sth = $dbh->prepare($sql);
$sth->execute(@selectors);

my @rows;
while (my $row = $sth->fetchrow_hashref) {
    push @rows, $row;
}

my $total = scalar @rows;
die "No records to convert\n" if $total == 0;

print "Fetched $total record(s) from the database.\n" if $verbose;

if ($engine eq 'xslt') {
    convert_with_xslt(\@rows);
} else {
    convert_with_plugin(\@rows);
}

sub convert_with_xslt {
    my ($rows) = @_;

    my $output = $output_file || 'bibframe.rdf';

    my @records;
    my $skipped = 0;
    my $parser = XML::LibXML->new();

    foreach my $row (@$rows) {
        my $biblionumber = $row->{biblionumber};
        my $xml = $row->{metadata};

        my $doc = eval { $parser->parse_string($xml) };
        if ($@ || !$doc) {
            warn "  Skipping biblionumber $biblionumber: invalid MARCXML ($@)\n";
            $skipped++;
            next;
        }

        # Re-serialize the record through libxml2 so it is always valid,
        # canonical UTF-8, regardless of how the bytes are stored in the
        # database. Convert it to a plain byte string so later string
        # operations do not re-encode it.
        $xml = encode_utf8($doc->documentElement->toString(0));
        push @records, { biblionumber => $biblionumber, xml => $xml };
    }

    my $converted = scalar @records;
    die "No valid records to convert\n" if $converted == 0;

    my @record_xml = map { $_->{xml} } @records;

    my $marcxml = join "\n", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        '<marc:collection',
        '    xmlns:marc="http://www.loc.gov/MARC21/slim"',
        '    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"',
        '    xsi:schemaLocation="http://www.loc.gov/MARC21/slim http://www.loc.gov/standards/marcxml/schema/MARC21slim.xsd">',
        @record_xml,
        '</marc:collection>',
        '';

    if (defined $keep_marcxml) {
        open my $kfh, '>', $keep_marcxml or die "Cannot write $keep_marcxml: $!\n";
        print $kfh $marcxml;
        close $kfh;
        print "MARCXML collection written to $keep_marcxml\n" if $verbose;
    }

    if ($dry_run) {
        print "Dry run: not writing $output\n" if $verbose;
        print "Would convert $converted record(s) to BIBFRAME RDF/XML.\n";
        return;
    }

    print "Converting $converted record(s) to BIBFRAME...\n" if $verbose;
    print "  xslt:    $xsl\n" if $verbose;
    print "  baseuri: $baseuri\n" if $verbose;

    my ($fh, $tmpfile) = tempfile('marc2bibframe-XXXXXX', SUFFIX => '.xml', UNLINK => 1);
    print $fh $marcxml;
    close $fh;

    my @cmd = ('xsltproc', '--stringparam', 'baseuri', $baseuri);
    push @cmd, ('--stringparam', 'idsource', $idsource) if defined $idsource;
    push @cmd, ('-o', $output, $xsl, $tmpfile);

    print "  cmd: @cmd\n" if $verbose;

    system(@cmd);
    if ($? != 0) {
        warn "Conversion failed (exit status $?)\n";
        exit 1;
    }

    print "BIBFRAME output written to $output\n";
    print "  " . (-s $output) . " bytes\n" if $verbose;
    if ($skipped) {
        print "  Skipped $skipped invalid record(s)\n";
    }
}

sub convert_with_plugin {
    my ($rows) = @_;

    my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
    my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();

    my $processed = 0;
    my $errors = 0;
    my $skipped = 0;

    say "Processing $total biblionumber(s)..." if $verbose;
    say "Output format: $format" if $verbose;
    say "Output file: $output_file" if $output_file && $verbose;
    say "";

    foreach my $row (@$rows) {
        my $biblionumber = $row->{biblionumber};

        eval {
            say "Processing biblionumber $biblionumber..." if $verbose;

            my $marc_record = eval { MARC::Record::new_from_xml($row->{metadata}, 'UTF-8', 'MARC21') };
            unless ($marc_record) {
                warn "  Warning: No MARC21 record found for biblionumber $biblionumber\n";
                $skipped++;
                return;
            }

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

            if ($dry_run) {
                say "  Dry run: not saving biblionumber $biblionumber" if $verbose;
            } elsif ($output_file) {
                save_to_file($biblionumber, $triples, $format, $output_file, $total);
            } else {
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

    say "=" x 60;
    say "Conversion Summary:";
    say "  Total biblionumbers: $total";
    say "  Successfully processed: $processed";
    say "  Skipped (no record): $skipped";
    say "  Errors: $errors";
    say "=" x 60;

    exit($errors > 0 ? 1 : 0);
}

=head2 save_to_file

Saves converted Bibframe data to a file

=cut

sub save_to_file {
    my ($biblionumber, $triples, $format, $output_file, $count) = @_;

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
    if ($count > 1) {
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

convert_marc_to_Bibframe.pl - Convert MARC21 records to Bibframe

=head1 SYNOPSIS

convert_marc_to_Bibframe.pl [options]

=head1 OPTIONS

=over 4

=item B<--engine=ENGINE>

Conversion engine: C<xslt> (default) or C<plugin>. The xslt engine runs
the marc2bibframe2 XSLT converter over all selected records in one pass and
writes a single RDF/XML file. The plugin engine uses the plugin's own
Bibframe module (Finnish BIBFRAME Implementation) and stores the result in
the biblio_metadata table or in per-record files.

=item B<--biblionumber=N> / B<--biblionumbers=N,M,...>

Convert one or more biblionumbers, comma-separated.

=item B<--file=FILE>

Convert the records listed in FILE, one biblionumber per line.

=item B<--range=N-M>

Convert a range of biblionumbers (inclusive).

=item B<--start=N> / B<--end=M>

Same as --range.

=item B<--all>

Convert all records in the database.

=item B<--limit=N>

Only convert up to N records (after --offset).

=item B<--offset=N>

Skip the first N records.

=item B<--format=FORMAT>

Plugin engine only: turtle (default), json-ld, ntriples, rdfxml, json.

=item B<--output=PATH>

xslt engine: the single RDF/XML output file (default: bibframe.rdf).
plugin engine: save to file(s) instead of the biblio_metadata table;
a biblionumber suffix is appended when multiple records are selected.

=item B<--xsl=PATH>

xslt engine only: path to marc2bibframe2.xsl (defaults to the copy
bundled in config/).

=item B<--baseuri=URI>

xslt engine only: URI stem used for minting entity URIs
(default: http://example.org/).

=item B<--idsource=URI>

xslt engine only: URI identifying the source of the record identifiers.

=item B<--keep-marcxml=FILE>

xslt engine only: also save the generated MARCXML collection.

=item B<--dry-run>

Do not write any output (plugin engine) or output file (xslt engine).

=item B<--verbose>

Print detailed output.

=item B<--help>

Print this help message.

=back

=head1 DESCRIPTION

This script fetches MARC21 records from the biblio_metadata table and
converts them to BIBFRAME using one of two engines:

=over 4

=item * xslt (default) - The official marc2bibframe2 XSLT converter
(https://github.com/lcnetdev/marc2bibframe2) is run with xsltproc over a
marc:collection of all selected records, producing one RDF/XML document.
Requires xsltproc and XML::LibXML.

=item * plugin - The plugin's Bibframe module produces RDF triples using
the Finnish BIBFRAME Implementation mapping. Results are stored in the
biblio_metadata table (format=turtle/json-ld/etc., schema='Bibframe') or
in per-record output files.

=back

=head1 EXAMPLES

Export a single record to RDF/XML with marc2bibframe2:

  ./convert_marc_to_Bibframe.pl --biblionumber=123 --output=123.rdf

Export a range of records with a custom URI stem:

  ./convert_marc_to_Bibframe.pl --range=100-200 --baseuri=http://mylibrary.org/

Convert all biblios to JSON-LD and store in the database:

  ./convert_marc_to_Bibframe.pl --all --engine=plugin --format=json-ld --verbose

Export biblios to Turtle files (one per record):

  ./convert_marc_to_Bibframe.pl --range=100-105 --engine=plugin --format=turtle --output=/tmp/biblio.ttl --verbose

=head1 AUTHOR

Koha-Suomi Oy

=head1 LICENSE

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

=cut
