#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;

# ---------------------------------------------------------------------------
# BFFI -> MARC value round-trip.
#
# The projection is validated against the authoritative stored MARC21 copy:
#
#   1. every significant value taken from the stored MARC must survive into the
#      projected BFFI graph, and
#   2. every aap / identifier value in the projection must be traceable back to
#      the stored MARC (no fabricated values).
#
# The MARC copy in this store is a pass-through reader (see MarcGenerator), so
# the round-trip is a value diff, not a byte-for-byte MARC regeneration.
#
# Inputs are optional; the test skips when none are supplied:
#   BFFI_ROUNDTRIP_MARC    path to stored MARC (MARCXML or ISO2709)
#   BFFI_ROUNDTRIP_RDF     path to the matching LoC BIBFRAME RDF/XML
#   BFFI_ROUNDTRIP_DB=1    query the live semantic store instead of files, with
#   BFFI_ROUNDTRIP_BIBLIO  the biblio id to read
#   BFFI_ROUNDTRIP_BASE    base URI for minted URIs (optional)
# ---------------------------------------------------------------------------

my $base_uri  = $ENV{BFFI_ROUNDTRIP_BASE} || 'http://urn.fi/URN:NBN:fi:bib:';
my $marc_path = $ENV{BFFI_ROUNDTRIP_MARC};
my $rdf_path  = $ENV{BFFI_ROUNDTRIP_RDF};
my $use_db    = $ENV{BFFI_ROUNDTRIP_DB};
my $biblio    = $ENV{BFFI_ROUNDTRIP_BIBLIO};

my $have_files = $marc_path && $rdf_path && -f $marc_path && -f $rdf_path;
my $have_db    = $use_db && $biblio;

plan skip_all => 'set BFFI_ROUNDTRIP_MARC + BFFI_ROUNDTRIP_RDF, or '
    . 'BFFI_ROUNDTRIP_DB=1 + BFFI_ROUNDTRIP_BIBLIO, to run the round-trip'
    unless $have_files || $have_db;

require Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector;
require Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
require MARC::Record;

my $BFFI = 'http://urn.fi/URN:NBN:fi:schema:bffi:';

# --- input loading ---------------------------------------------------------

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "open $path: $!";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub load_marc {
    my ($path) = @_;
    my $data = slurp($path);
    if ($data =~ /^[\x00-\x1f]{5}/) {    # ISO2709 leader
        require MARC::File::USMARC;
        return MARC::File::USMARC->decode($data);
    }
    return MARC::Record->new_from_xml($data, 'UTF-8', 'MARC21');
}

my ($marc, $loc_triples);

if ($have_files) {
    $marc = load_marc($marc_path);
    my $bibframe = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
    $loc_triples = $bibframe->rdf_to_triples(slurp($rdf_path));
} else {
    require Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::MarcGenerator;
    require Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator;
    $marc = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::MarcGenerator->new()
        ->get_record(biblio_id => $biblio);
    $loc_triples = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator->new()
        ->generate_triples(biblio_id => $biblio);
}

ok($marc, 'authoritative stored MARC21 record is available');
ok($loc_triples && @$loc_triples, 'stored LoC BIBFRAME triples are available');
unless ($marc && $loc_triples && @$loc_triples) {
    done_testing();
    exit 0;
}

# --- projection ------------------------------------------------------------

my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new(
    base_uri => $base_uri,
);
my $bffi = $projector->project($loc_triples, base_uri => $base_uri);

ok($bffi && @$bffi, 'projection produced BFFI triples');
is(scalar($projector->closed_namespace_violations($bffi)), 0,
    'projection stays in the closed bffi: namespace');

# --- value indexes ---------------------------------------------------------

sub norm {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\s+/ /g;
    $s =~ s/^ +| +$//g;
    $s =~ s{[\s.,;:/=]+$}{};
    return lc $s;
}

my (%proj_literals, @proj_aap, @proj_identifier);
for my $t (@$bffi) {
    if (($t->{object_type} || '') eq 'uri') {
        # A value-vocabulary reference preserves its code (e.g. a language
        # resource .../languages/eng preserves the MARC 041 'eng' code).
        (my $local = $t->{object}) =~ s{.*[/#]}{};
        my $n = norm($local);
        $proj_literals{$n} = 1 if length $n;
        next;
    }
    my $value = $t->{object};
    my $n = norm($value);
    $proj_literals{$n} = $value if length $n;

    my ($local) = $t->{predicate} =~ m{[:#/]([^:#/]+)$};
    push @proj_aap, $value if $local && $local eq 'aap';
    push @proj_identifier, $value if $t->{predicate} eq 'rdf:value';
}

# Significant MARC values that must survive the projection. Tags are chosen so
# each carries a discoverable value rather than structural noise.
my @TRACKED_TAGS = qw(
    010 020 022 024 028 041 100 110 111 130 240 245 246 250 264 490 700 710 730 830
);

my @marc_values;
for my $tag (@TRACKED_TAGS) {
    for my $field ($marc->field($tag)) {
        for my $sub ($field->subfields) {
            my (undef, $value) = @$sub;
            next unless defined $value && length $value;
            push @marc_values, $value;
        }
    }
}

sub preserved {
    my ($value) = @_;
    my $n = norm($value);
    return 0 unless length $n;
    return 1 if exists $proj_literals{$n};
    for my $candidate (keys %proj_literals) {
        return 1 if index($candidate, $n) >= 0 || index($n, $candidate) >= 0;
    }
    return 0;
}

# 1. Preservation direction: MARC value -> projection.
my @lost = grep { !preserved($_) } @marc_values;
is(scalar @lost, 0, sprintf('all %d tracked MARC values survive projection', scalar @marc_values))
    or diag "lost values: @lost";

# 2. Fabrication direction: projection aap / identifier -> MARC.
my $usmarc = eval { $marc->as_usmarc() } // '';
my $compact = norm($usmarc);
$compact =~ s/\s+//g;
my @fabricated = grep {
    my $c = norm($_);
    $c =~ s/\s+//g;
    length $c && index($compact, $c) < 0;
} (@proj_aap, @proj_identifier);
is(scalar @fabricated, 0, 'no fabricated aap / identifier values in projection')
    or diag "fabricated: @fabricated";

# 3. Structural expectations.
my %types;
for my $t (@$bffi) {
    next unless $t->{predicate} eq 'rdf:type' && ($t->{object_type} || '') eq 'uri';
    $types{ $t->{object} }++;
}
ok($types{ $BFFI . 'Work' } || $types{ $BFFI . 'Manifestation' },
    'projection contains a top-level Work or Manifestation');

done_testing();
