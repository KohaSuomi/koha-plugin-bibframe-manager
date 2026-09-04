package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use C4::Context;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator

=head1 DESCRIPTION

Phase 11: Exports LoC BIBFRAME 3-level RDF triples from the semantic store.

Reads the canonical core tables (record_resources, record_properties,
record_links) and materializes them as LoC-style triple hashrefs:

    { subject => $uri, predicate => $pred, object => $value,
      object_type => 'uri'|'literal', lang => $lang }

Predicates use the LoC BIBFRAME vocabulary
(http://id.loc.gov/ontologies/bibframe/...). Type triples use the local
predicate 'rdf:type'. The Work -> Instance and Instance -> Work containment
links use the /hasInstance and /instanceOf predicate forms so the output can be
fed to BFFIGenerator for 4-level WEMI derivation on export.

The canonical stored model is the LoC 3-level (Work -> Instance -> Item); the
4-level WEMI (with Expression) is derived only on BFFI export via BFFIGenerator.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    bless($self, $class);
    return $self;
}

sub dbh {
    return C4::Context->dbh;
}

my $BF_NS    = 'http://id.loc.gov/ontologies/bibframe/';
my $RDFS_NS  = 'http://www.w3.org/2000/01/rdf-schema#';
my $RDF_NS   = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';

# LoC resource_type -> full type URI
my %LOC_TYPE_URI = (
    Work         => $BF_NS . 'Work',
    Instance     => $BF_NS . 'Instance',
    Item         => $BF_NS . 'Item',
    Agent        => $BF_NS . 'Agent',
    Person       => $BF_NS . 'Agent',
    Organization => $BF_NS . 'Agent',
    Meeting      => $BF_NS . 'Agent',
    Family       => $BF_NS . 'Agent',
    Topic        => $BF_NS . 'Topic',
    GenreForm    => $BF_NS . 'GenreForm',
    Geographic   => $BF_NS . 'Place',
    Temporal     => $BF_NS . 'Temporal',
    Language     => $BF_NS . 'Language',
    Place        => $BF_NS . 'Place',
    AdminMetadata=> $BF_NS . 'AdminMetadata',
);

=head1 PUBLIC METHODS

=head2 generate_triples

    my $triples = $gen->generate_triples(resource_id => $id);
    my $triples = $gen->generate_triples(biblio_id => $biblio_id);

Reads the stored canonical graph for a resource (or a whole biblio graph) and
returns an arrayref of LoC 3-level triple hashrefs.

=cut

sub generate_triples {
    my ($self, %args) = @_;

    my $resource_id = $args{resource_id};
    my $biblio_id   = $args{biblio_id};

    my $graph_ids = $self->_load_graph_resource_ids($resource_id, $biblio_id);
    return [] unless @$graph_ids;

    my @triples;

    my $resources = $self->_load_resources($graph_ids);
    my $properties = $self->_load_properties($graph_ids);
    my $links = $self->_load_links($graph_ids);

    # Emit type + label + properties for each resource
    for my $res (@$resources) {
        $self->_emit_resource_triples($res, $properties->{$res->{id}}, \@triples);
    }

    # Emit relationship links
    for my $link (@$links) {
        $self->_emit_link_triples($link, \@triples);
    }

    return \@triples;
}

=head2 generate

    my $serialized = $gen->generate(resource_id => $id, format => 'json');

Returns the LoC 3-level graph in the requested serialization format
('json','rdf-xml','turtle','ntriples','json-ld'). Delegates to
Database::serializeTriples.

=cut

sub generate {
    my ($self, %args) = @_;

    my $format   = $args{format} || 'json';
    my $triples  = $self->generate_triples(%args);
    return undef unless $triples && @$triples;

    my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
    return $db->serializeTriples($triples, $format);
}

=head1 PRIVATE METHODS

=cut

# Determines the set of resource ids that form the graph to export.
sub _load_graph_resource_ids {
    my ($self, $resource_id, $biblio_id) = @_;

    my $dbh = $self->dbh;
    my @ids;

    if ($biblio_id) {
        # All resources belonging to the biblio graph
        my $sth = $dbh->prepare(
            'SELECT id FROM record_resources WHERE biblio_id = ?'
        );
        $sth->execute($biblio_id);
        while (my $row = $sth->fetchrow_hashref()) { push @ids, $row->{id}; }
    } elsif ($resource_id) {
        # The resource plus everything it is linked to (transitively, one hop)
        my %seen = ($resource_id => 1);
        my @queue = ($resource_id);
        while (@queue) {
            my $cur = shift @queue;
            my $sth = $dbh->prepare(
                "SELECT source_resource_id, target_resource_id FROM record_links
                 WHERE source_resource_id = ? OR target_resource_id = ?"
            );
            $sth->execute($cur, $cur);
            while (my $row = $sth->fetchrow_hashref()) {
                for my $other ($row->{source_resource_id}, $row->{target_resource_id}) {
                    next if $seen{$other};
                    $seen{$other} = 1;
                    push @queue, $other;
                }
            }
        }
        @ids = keys %seen;
    }

    return \@ids;
}

sub _load_resources {
    my ($self, $graph_ids) = @_;

    return [] unless @$graph_ids;
    my $placeholders = join ',', ('?') x @$graph_ids;

    my $sth = $self->dbh->prepare(
        "SELECT id, uri, resource_type, label, biblio_id, item_id
         FROM record_resources WHERE id IN ($placeholders)"
    );
    $sth->execute(@$graph_ids);
    return $sth->fetchall_arrayref({});
}

sub _load_properties {
    my ($self, $graph_ids) = @_;

    return {} unless @$graph_ids;
    my $placeholders = join ',', ('?') x @$graph_ids;

    my $sth = $self->dbh->prepare(
        "SELECT resource_id, property_uri, property_key, value_type,
                value_text, value_lang, value_resource_id
         FROM record_properties WHERE resource_id IN ($placeholders)
         ORDER BY resource_id, sequence"
    );
    $sth->execute(@$graph_ids);

    my %props;
    while (my $row = $sth->fetchrow_hashref()) {
        push @{$props{$row->{resource_id}}}, $row;
    }
    return \%props;
}

sub _load_links {
    my ($self, $graph_ids) = @_;

    return [] unless @$graph_ids;
    my $placeholders = join ',', ('?') x @$graph_ids;

    my $sth = $self->dbh->prepare(
        "SELECT l.id, l.source_resource_id, l.target_resource_id,
                l.relationship_type, l.relationship_uri,
                src.uri AS source_uri, tgt.uri AS target_uri
         FROM record_links l
         JOIN record_resources src ON src.id = l.source_resource_id
         JOIN record_resources tgt ON tgt.id = l.target_resource_id
         WHERE l.source_resource_id IN ($placeholders)
            OR l.target_resource_id IN ($placeholders)"
    );
    $sth->execute(@$graph_ids, @$graph_ids);
    return $sth->fetchall_arrayref({});
}

sub _emit_resource_triples {
    my ($self, $res, $props, $triples) = @_;

    return unless $res->{uri};

    # rdf:type
    my $type_uri = $LOC_TYPE_URI{$res->{resource_type}};
    if ($type_uri) {
        push @$triples, {
            subject     => $res->{uri},
            predicate   => 'rdf:type',
            object      => $type_uri,
            object_type => 'uri',
        };
    }

    # rdfs:label
    if (defined $res->{label} && length $res->{label}) {
        push @$triples, {
            subject     => $res->{uri},
            predicate   => 'rdfs:label',
            object      => $res->{label},
            object_type => 'literal',
        };
    }

    return unless $props;

    # Properties (predicates use the stored LoC property URI)
    for my $prop (@$props) {
        next unless defined $prop->{value_text} && length $prop->{value_text};

        my $pred = $prop->{property_uri} || $prop->{property_key};
        push @$triples, {
            subject     => $res->{uri},
            predicate   => $pred,
            object      => $prop->{value_text},
            object_type => 'literal',
            ($prop->{value_lang} ? (lang => $prop->{value_lang}) : ()),
        };
    }
}

sub _emit_link_triples {
    my ($self, $link, $triples) = @_;

    return unless $link->{source_uri} && $link->{target_uri};

    my $pred = $link->{relationship_uri} || $self->_link_predicate($link->{relationship_type});

    push @$triples, {
        subject     => $link->{source_uri},
        predicate   => $pred,
        object      => $link->{target_uri},
        object_type => 'uri',
    };
}

# Maps the stored relationship_type to a LoC/ended predicate form so derived
# BFFI export can recognize Work->Instance containment.
sub _link_predicate {
    my ($self, $rel_type) = @_;

    return $BF_NS . 'hasInstance' if $rel_type eq 'hasInstance';
    return $BF_NS . 'instanceOf'  if $rel_type eq 'instanceOf';
    return $BF_NS . 'hasPart'     if $rel_type eq 'hasPart';
    return $BF_NS . 'partOf'      if $rel_type eq 'partOf';
    return $BF_NS . 'hasItem'     if $rel_type eq 'hasItem';
    return $BF_NS . 'itemOf'      if $rel_type eq 'itemOf';
    return $BF_NS . 'contribution' if $rel_type =~ /contributor|creator/;
    return $BF_NS . 'subject'     if $rel_type eq 'subject';

    # Fall back to a generic relationship on the bf namespace
    return $BF_NS . ($rel_type || 'relatedTo');
}

1;
