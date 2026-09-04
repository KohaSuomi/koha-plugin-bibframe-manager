package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIGenerator;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIGenerator

=head1 DESCRIPTION

Phase 11: Derives BFFI 4-level WEMI (Work -> Expression -> Manifestation ->
Item) RDF from the canonical LoC 3-level store on export.

The canonical stored model is the LoC 3-level (Work -> Instance -> Item). The
Expression level is NOT persisted; it is derived on demand, only when a BFFI
export is requested. This module:

  1. Reads the stored LoC 3-level graph via BibframeGenerator.
  2. Derives the 4-level WEMI via Bibframe::derive_wemi_from_loc.
  3. Serializes the derived BFFI graph.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    bless($self, $class);
    return $self;
}

=head1 PUBLIC METHODS

=head2 generate_triples

    my $triples = $gen->generate_triples(resource_id => $id, base_uri => $uri);

Returns the derived BFFI 4-level WEMI triple hashrefs, or an empty arrayref if
the stored graph could not be read.

=cut

sub generate_triples {
    my ($self, %args) = @_;

    my $generator = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator->new();
    my $loc_triples = $generator->generate_triples(%args);

    return [] unless $loc_triples && @$loc_triples;

    my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
    my $base_uri = $args{base_uri} || 'http://urn.fi/URN:NBN:fi:bib:';

    return $converter->derive_wemi_from_loc($loc_triples, base_uri => $base_uri);
}

=head2 generate

    my $serialized = $gen->generate(resource_id => $id, format => 'turtle');

Returns the derived BFFI 4-level WEMI graph in the requested serialization
format ('json','rdf-xml','turtle','ntriples','json-ld').

=cut

sub generate {
    my ($self, %args) = @_;

    my $format  = $args{format} || 'json';
    my $triples = $self->generate_triples(%args);

    return undef unless $triples && @$triples;

    my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
    return $db->serializeTriples($triples, $format);
}

1;
