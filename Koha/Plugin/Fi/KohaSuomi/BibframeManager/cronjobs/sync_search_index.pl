#!/usr/bin/perl

# Copyright 2026 KohaSuomi
#
# This script syncs bibliographic data from the hybrid storage layer
# (summary + core tables) to the Elasticsearch search index.
#
# ES is a derived search index, never the source of truth. Configuration is
# plugin-specific (decoupled from Koha's own Elasticsearch):
#
#   koha-conf.xml  <bibframe_manager> es_server, es_index, es_username,
#                  es_password, es_enabled
#   environment    BIBFRAME_ES_SERVER, BIBFRAME_ES_INDEX, BIBFRAME_ES_ENABLED
#
# Usage:
#   perl sync_search_index.pl --all
#   perl sync_search_index.pl --biblionumber=123,124,125
#   perl sync_search_index.pl --range=1-100
#   perl sync_search_index.pl --index 123          # upsert one
#   perl sync_search_index.pl --delete 123         # remove one

use Modern::Perl;
use Getopt::Long qw(GetOptions);
use utf8;
use open ':std', ':encoding(UTF-8)';
use Pod::Usage;
use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex;

my $all;
my $biblionumber_str;
my $from_file;
my $range;
my $index_one;
my $delete_one;
my $model;
my $verbose;
my $help;

GetOptions(
    'all'               => \$all,
    'biblionumber=s'    => \$biblionumber_str,
    'file=s'            => \$from_file,
    'range=s'           => \$range,
    'index=i'           => \$index_one,
    'delete=i'          => \$delete_one,
    'model=s'           => \$model,
    'verbose'           => \$verbose,
    'help|?'            => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

my %search_args;
$search_args{es_model} = $model if defined $model && length $model;

my $search = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex->new(%search_args);

if (defined $delete_one) {
    $search->delete_document($delete_one);
    say "Deleted doc for biblio $delete_one";
    exit 0;
}

if (defined $index_one) {
    my $ok = $search->index_document($index_one);
    say $ok ? "Indexed biblio $index_one" : "No stored data for biblio $index_one";
    exit 0;
}

my @ids;

if ($biblionumber_str) {
    @ids = split /,/, $biblionumber_str;
} elsif ($from_file) {
    open my $fh, '<', $from_file or die "Cannot open $from_file: $!";
    chomp(@ids = <$fh>);
    close $fh;
} elsif ($range) {
    my ($lo, $hi) = split /-/, $range;
    @ids = ($lo .. $hi);
} elsif ($all) {
    my $sth = C4::Context->dbh->prepare(
        'SELECT DISTINCT biblio_id FROM record_resources WHERE biblio_id IS NOT NULL'
    );
    $sth->execute();
    while (my $row = $sth->fetchrow_hashref()) { push @ids, $row->{biblio_id}; }
} else {
    pod2usage(1);
}

@ids = grep { defined && length } @ids;

say "Syncing " . scalar(@ids) . " biblio(s) to index '" . $search->_index() . "'"
    if $verbose;

my $count = $search->index_biblios(\@ids);
say "Indexed $count document(s)";

=head1 NAME

sync_search_index.pl

=head1 SYNOPSIS

sync_search_index.pl --all
sync_search_index.pl --biblionumber=123,124,125
sync_search_index.pl --file=numbers.txt
sync_search_index.pl --range=1-100
sync_search_index.pl --index 123
sync_search_index.pl --delete 123
sync_search_index.pl --model=wemi-4 --all

=head1 DESCRIPTION

Syncs bibliographic documents from the hybrid storage layer to Elasticsearch.
The document model is selected by the es_mapping.yaml C<model> key
(C<loc-3>, C<wemi-4> or C<loc-raw>); pass C<--model> to override.

=head1 OPTIONS

=over 8

=item B<--all>

Sync all biblios with stored semantic data

=item B<--biblionumber=N,M,...>

Sync specific biblio numbers (comma-separated)

=item B<--file=FILE>

Sync biblio numbers listed in FILE (one per line)

=item B<--range=N-M>

Sync a range of biblio numbers

=item B<--index=N>

Upsert a single biblio document

=item B<--delete=N>

Delete a single biblio document

=item B<--model=MODEL>

Document model override (loc-3, wemi-4 or loc-raw); defaults to the
es_mapping.yaml C<model> key

=item B<--verbose>

Print progress information

=item B<--help>

Show this help

=back

=head1 SEE ALSO

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex

=cut
