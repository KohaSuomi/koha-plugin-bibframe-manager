package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector;

use strict;
use warnings;
use utf8;

use YAML::XS qw(LoadFile);
use File::Spec;
use Digest::SHA qw(sha1_hex);

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector

=head1 DESCRIPTION

Projects the canonical LoC 3-level BIBFRAME graph (Work -> Instance -> Item)
onto a closed-namespace BFFI 4-level graph (Work -> Expression -> Manifestation
-> Item) for export.

Unlike the legacy L<Bibframe::derive_wemi_from_loc>, which only renames the
outer node types and otherwise copies LoC predicates verbatim, this module
renames classes and predicates through the ontology-derived table in
F<config/bffi_rename.yaml> so that the output contains only C<bffi:> terms.

The module is deliberately free of Koha dependencies (no C<C4::Context>): it
takes triple hashrefs and returns triple hashrefs, which keeps it unit
testable in isolation. Wiring to the store lives in BFFIGenerator.

Triple representation (same as the rest of the plugin):

    { subject => $uri, predicate => $pred, object => $value,
      object_type => 'uri'|'literal', lang => $lang }

Predicates may be abbreviated (C<bf:title>, C<rdf:type>) or full URIs.

=cut

my $BF   = 'http://id.loc.gov/ontologies/bibframe/';
my $BFLC = 'http://id.loc.gov/ontologies/bflc/';
my $RDF  = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
my $RDFS = 'http://www.w3.org/2000/01/rdf-schema#';
my $DCT  = 'http://purl.org/dc/terms/';
my $BFFI = 'http://urn.fi/URN:NBN:fi:schema:bffi:';

my %NS = (
    bf      => $BF,
    bflc    => $BFLC,
    rdf     => $RDF,
    rdfs    => $RDFS,
    dcterms => $DCT,
    bffi    => $BFFI,
);

# Properties that describe the realization and therefore belong on the
# Expression rather than the Work. Keyed by the LoC local name.
my %EXPRESSION_PROPS = map { $_ => 1 } qw(
    language languageOfExpression contentType content edition
    editionStatement note reproduction supplementaryContent
);

# LoC combined Work+Expression types split into their BFFI Work/Expression
# sub-classes (the BFFI "axis" split).
my %AXIS_TYPES = (
    Monograph           => ['bffi:MonographWork',      'bffi:MonographExpression'],
    MultipartMonograph  => ['bffi:MonographWork',      'bffi:MonographExpression'],
    Serial              => ['bffi:SerialWork',         'bffi:SerialExpression'],
    IntegrateResource   => ['bffi:Integrating',        'bffi:IntegratingExpression'],
    Music               => ['bffi:MusicWork',          'bffi:MusicAudioExpression'],
    NotatedMusic        => ['bffi:NotatedMusicWork',   'bffi:NotatedMusic'],
    Cartographic        => ['bffi:CartographyWork',    'bffi:CartographyExpression'],
    MovingImage         => ['bffi:MovingImageWork',    'bffi:MovingImageExpression'],
    Audio               => ['bffi:NonMusicAudioWork',  'bffi:NonMusicAudioExpression'],
    SoundRecording      => ['bffi:NonMusicAudioWork',  'bffi:NonMusicAudioExpression'],
);

# LoC Identifier sub-classes -> LoC identifier scheme token used to build the
# bffi:source URI (http://id.loc.gov/vocabulary/identifiers/{token}).
my %IDENTIFIER_SCHEMES = (
    Isbn              => 'isbn',
    Issn              => 'issn',
    Ismn              => 'ismn',
    Doi               => 'doi',
    Lccn              => 'lccn',
    Upc               => 'upc',
    Local             => 'local',
    OtherIdentifier   => 'other',
    VideoRecordingNumber => 'videorecording-number',
);
my $ID_SCHEME_NS = 'http://id.loc.gov/vocabulary/identifiers/';

my $RENAME;

sub _load_rename {
    return $RENAME if $RENAME;

    my $module_dir = __FILE__;
    $module_dir =~ s/BFFIProjector\.pm$//;
    my $config = File::Spec->catfile($module_dir, '..', 'config', 'bffi_rename.yaml');
    die "BFFI rename configuration not found: $config\n" unless -f $config;

    $RENAME = LoadFile($config) || {};
    return $RENAME;
}

sub new {
    my ($class, %args) = @_;
    my $self = {
        base_uri => $args{base_uri} || 'http://urn.fi/URN:NBN:fi:bib:',
        rename   => $args{rename} || _load_rename(),
    };
    bless($self, $class);
    $self->{stats} = {
        kept            => 0,
        renamed         => 0,
        dropped         => 0,
        dropped_terms   => {},
    };
    return $self;
}

sub stats {
    my ($self) = @_;
    return $self->{stats};
}

=head2 project

    my $triples = $projector->project($loc_triples, base_uri => $uri);

Returns an arrayref of BFFI triple hashrefs. Routing counters are available
via C<$projector->stats> after the call.

=cut

sub project {
    my ($self, $loc_triples, %opts) = @_;

    $self->{base_uri} = $opts{base_uri} if $opts{base_uri};
    $self->{stats} = { kept => 0, renamed => 0, dropped => 0, dropped_terms => {} };

    return [] unless $loc_triples && @$loc_triples;

    my %by_subject;
    push @{ $by_subject{ $_->{subject} } }, $_ for @$loc_triples;

    my ($work, $instance, $item) = $self->_core_subjects(\%by_subject);
    return [] unless $work || $instance;

    my $id = $self->_derive_id($work, $instance);

    my %uri_map;
    $uri_map{$work}     = $self->_mint('work', $id)          if $work;
    $uri_map{$instance} = $self->_mint('manifestation', $id) if $instance;
    $uri_map{$item}     = $self->_mint('item', $id)          if $item;
    my $expression_uri = $self->_mint('expression', $id);

    my $axis = $work ? $self->_axis_pair($by_subject{$work}) : undef;

    my $work_aap = $work
        ? (grep { _loc_local($_->{predicate}) && _loc_local($_->{predicate}) eq 'aap' }
            @{ $by_subject{$work} })[0]
        : undef;

    my @out;

    if ($work) {
        $self->_emit_work($by_subject{$work}, $uri_map{$work}, $expression_uri, $axis, $id, \@out);
    }

    if ($work) {
        $self->_emit_expression($by_subject{$work}, $expression_uri, $uri_map{$work}, $axis, $id, $work_aap, \@out);
    }

    my $work_uri = defined $work ? $uri_map{$work} : undef;

    if ($instance) {
        $self->_emit_manifestation($by_subject{$instance}, $uri_map{$instance},
            $expression_uri, $work_uri, \%uri_map, $id, $work_aap, \@out);
    }

    if ($item) {
        $self->_emit_item($by_subject{$item}, $uri_map{$item}, $uri_map{$instance}, \%uri_map, \@out);
    }

    $self->_emit_referenced_aux(\%by_subject, \%uri_map, \@out);

    # RDF is a set: collapse duplicate triples inherited from the source
    # while preserving first-occurrence order.
    my (%seen, @unique);
    for my $t (@out) {
        my $key = join "\x1f",
            $t->{subject}, $t->{predicate}, $t->{object},
            ($t->{object_type} // ''), ($t->{lang} // ''), ($t->{datatype} // '');
        next if $seen{$key}++;
        push @unique, $t;
    }

    return \@unique;
}

=head2 closed_namespace_violations

    my @bad = $projector->closed_namespace_violations($triples);

Returns the list of predicates (and C<rdf:type> objects) that still use a LoC
BIBFRAME/BFLC namespace, i.e. would break the closed-namespace guarantee.

=cut

sub closed_namespace_violations {
    my ($self, $triples) = @_;

    my @bad;
    for my $t (@$triples) {
        my $p = $t->{predicate};
        push @bad, $p if defined $p && _is_loc_ns($p);
        if ($t->{predicate} eq 'rdf:type' && ($t->{object_type} || '') eq 'uri') {
            push @bad, $t->{object} if _is_loc_ns($t->{object});
        }
    }
    return @bad;
}

# ---------------------------------------------------------------------------
# Level emission
# ---------------------------------------------------------------------------

sub _emit_work {
    my ($self, $triples, $uri, $expression_uri, $axis, $id, $out) = @_;

    push @$out, _type($uri, $self->_map_class($BF . 'Work', 'bffi:Work'));
    push @$out, _type($uri, $axis->[0]) if $axis;

    for my $t (@$triples) {
        my $pred = $t->{predicate};

        if ($pred eq 'rdf:type') {
            next unless ($t->{object_type} || '') eq 'uri';
            next if _canon_uri($t->{object}) eq $BF . 'Work';
            my $mapped = $self->_map_class($t->{object});
            push @$out, _type($uri, $mapped) if $mapped;
            next;
        }

        next if $pred =~ m{/hasInstance$} || $pred eq 'bf:hasInstance';
        next if $pred =~ m{/instanceOf$}  || $pred eq 'bf:instanceOf';

        # Contributions are reified as bffi:Contribution nodes below.
        my $lloc = _loc_local($pred);
        next if $lloc && ($lloc eq 'agent' || $lloc eq 'role');

        if ($lloc && $EXPRESSION_PROPS{$lloc}) {
            next;    # handled by _emit_expression
        }

        my $renamed = $self->_rename_predicate($pred);
        next unless $renamed;
        push @$out, _copy($t, $uri, $renamed);
    }

    $self->_emit_contributions($uri, $id, $triples, $out);

    push @$out, _uri($uri, $BFFI . 'hasExpression', $expression_uri);
}

sub _emit_expression {
    my ($self, $work_triples, $uri, $work_uri, $axis, $id, $work_aap, $out) = @_;

    push @$out, _type($uri, $BFFI . 'Expression');

    $work_triples ||= [];
    my $is_text = grep {
        $_->{predicate} eq 'rdf:type'
            && ($_->{object_type} || '') eq 'uri'
            && _canon_uri($_->{object}) eq $BF . 'Text'
    } @$work_triples;
    push @$out, _type($uri, $BFFI . 'Text') if $is_text;
    push @$out, _type($uri, $axis->[1]) if $axis;

    # The Expression inherits the Work's authorized access point when the
    # source carries none of its own.
    push @$out, _copy($work_aap, $uri, $BFFI . 'aap') if $work_aap;

    for my $t (@$work_triples) {
        my $pred = $t->{predicate};
        next if $pred eq 'rdf:type';

        my $local = _loc_local($pred);
        next unless $local && $EXPRESSION_PROPS{$local};

        my $renamed = $self->_rename_predicate($pred);
        next unless $renamed;
        push @$out, _copy($t, $uri, $renamed);
    }

    push @$out, _uri($uri, $BFFI . 'expressionOf', $work_uri) if $work_uri;
}

sub _emit_manifestation {
    my ($self, $triples, $uri, $expression_uri, $work_uri, $uri_map, $id, $work_aap, $out) = @_;

    push @$out, _type($uri, $self->_map_class($BF . 'Instance', 'bffi:Manifestation'));

    my $has_own_aap = grep { _loc_local($_->{predicate}) && _loc_local($_->{predicate}) eq 'aap' } @$triples;

    for my $t (@$triples) {
        my $pred = $t->{predicate};

        if ($pred eq 'rdf:type') {
            next unless ($t->{object_type} || '') eq 'uri';
            next if _canon_uri($t->{object}) eq $BF . 'Instance';
            my $mapped = $self->_map_class($t->{object});
            push @$out, _type($uri, $mapped) if $mapped;
            next;
        }

        next if $pred =~ m{/instanceOf$} || $pred eq 'bf:instanceOf';
        next if $pred =~ m{/hasItem$}    || $pred eq 'bf:hasItem';

        my $lloc = _loc_local($pred);
        next if $lloc && ($lloc eq 'agent' || $lloc eq 'role');

        my $renamed = $self->_rename_predicate($pred);
        next unless $renamed;
        push @$out, _copy($t, $uri, $renamed, $uri_map);
    }

    $self->_emit_contributions($uri, $id, $triples, $out);

    push @$out, _copy($work_aap, $uri, $BFFI . 'aap') if $work_aap && !$has_own_aap;

    push @$out, _uri($uri, $BFFI . 'expressionManifested', $expression_uri);
    push @$out, _uri($uri, $BFFI . 'workManifested', $work_uri) if $work_uri;
    push @$out, _uri($expression_uri, $BFFI . 'manifestationOfExpression', $uri);
}

# Reify the flattened bf:agent / bf:role pairs on an entity as
# bffi:Contribution nodes (one per agent/role pair); agents or roles without a
# counterpart are kept directly on the entity so nothing is silently lost.
sub _emit_contributions {
    my ($self, $subject_uri, $id, $triples, $out) = @_;

    my (@agents, @roles);
    for my $t (@$triples) {
        next unless ($t->{object_type} || '') eq 'uri';
        my $local = _loc_local($t->{predicate});
        next unless $local;
        push @agents, $t->{object} if $local eq 'agent';
        push @roles,  $t->{object} if $local eq 'role';
    }

    return unless @agents || @roles;

    my $pair = @roles < @agents ? scalar(@roles) : scalar(@agents);
    for my $k (0 .. $pair - 1) {
        my $contrib = $self->_mint('contribution', "$id-c" . ($k + 1));
        push @$out, _type($contrib, $BFFI . 'Contribution');
        push @$out, _uri($subject_uri, $BFFI . 'contribution', $contrib);
        push @$out, _uri($contrib, $BFFI . 'agent', $agents[$k]);
        push @$out, _uri($contrib, $BFFI . 'role',  $roles[$k]);
    }
    for my $k ($pair .. $#agents) { push @$out, _uri($subject_uri, $BFFI . 'agent', $agents[$k]); }
    for my $k ($pair .. $#roles)  { push @$out, _uri($subject_uri, $BFFI . 'role',  $roles[$k]); }
}

sub _emit_item {
    my ($self, $triples, $uri, $instance_uri, $uri_map, $out) = @_;

    push @$out, _type($uri, $BFFI . 'Item');

    for my $t (@$triples) {
        my $pred = $t->{predicate};
        next if $pred eq 'rdf:type';

        my $renamed = $self->_rename_predicate($pred);
        next unless $renamed;
        push @$out, _copy($t, $uri, $renamed, $uri_map);
    }

    push @$out, _uri($uri, $BFFI . 'itemOf', $instance_uri) if $instance_uri;
}

# ---------------------------------------------------------------------------
# Axis split / referenced resources
# ---------------------------------------------------------------------------

# Returns [$work_class, $expression_class] full URIs for the Work's LoC type,
# i.e. the BFFI axis split, or undef when none is known.
sub _axis_pair {
    my ($self, $work_triples) = @_;

    for my $t (@$work_triples) {
        next unless $t->{predicate} eq 'rdf:type';
        next unless ($t->{object_type} || '') eq 'uri';
        my $local = _loc_local($t->{object});
        $local ||= ($t->{object} =~ m{/([^/]+)$})[0];
        next unless $local;
        if (my $pair = $AXIS_TYPES{$local}) {
            return [ $self->_expand($pair->[0]), $self->_expand($pair->[1]) ];
        }
    }
    return undef;
}

# Emit the stored triples of every URI object referenced by the projected
# graph (languages, topics, identifiers, agents, admin metadata...), with
# classes and predicates renamed through the same table so the output stays in
# a closed bffi: namespace. This is what turns plain references into usable
# entity sub-graphs, mirroring the reference converter's entity handling.
sub _emit_referenced_aux {
    my ($self, $by_subject, $uri_map, $out) = @_;

    my %emitted;
    my $i = 0;
    while ($i < @$out) {
        my $t = $out->[$i++];
        next unless ($t->{object_type} || '') eq 'uri';
        my $uri = $t->{object};

        next unless $by_subject->{$uri};          # unknown / unloaded
        next if $emitted{$uri}++;
        next if $uri =~ m{^\Q$BFFI\E};            # internal minted/structure

        my $identifier_scheme;
        for my $s (@{ $by_subject->{$uri} }) {
            next unless $s->{predicate} eq 'rdf:type' && ($s->{object_type} || '') eq 'uri';
            my ($local) = $s->{object} =~ m{/([^/]+)$};
            next unless $local;
            if (exists $IDENTIFIER_SCHEMES{$local}) {
                $identifier_scheme ||= $IDENTIFIER_SCHEMES{$local};
            }
        }

        if ($identifier_scheme) {
            push @$out, _type($uri, $BFFI . 'Identifier');
            push @$out, _uri($uri, $BFFI . 'source', $ID_SCHEME_NS . $identifier_scheme);
        }

        for my $s (@{ $by_subject->{$uri} }) {
            my $pred = $s->{predicate};

            if ($pred eq 'rdf:type') {
                next unless ($s->{object_type} || '') eq 'uri';
                next if $identifier_scheme;    # Identifier type already emitted
                my $mapped = $self->_map_class($s->{object});
                push @$out, _type($uri, $mapped) if $mapped;
                next;
            }

            if ($pred eq 'rdfs:label' || $pred eq "${RDFS}label") {
                push @$out, _copy($s, $uri, 'rdfs:label', $uri_map);
                next;
            }

            my $renamed = $self->_rename_predicate($pred);
            next unless $renamed;
            push @$out, _copy($s, $uri, $renamed, $uri_map);
        }
    }
}

sub _rename_predicate {
    my ($self, $pred) = @_;

    return 'rdf:type'   if $pred eq 'rdf:type';
    return 'rdfs:label' if $pred eq 'rdfs:label' || $pred eq "${RDFS}label";

    my $abbrev = $self->_abbrev($pred);

    # Standard RDF/RDFS predicates are not part of BIBFRAME and carry no
    # closed-namespace concern; keep them verbatim.
    return $abbrev if $abbrev =~ /^rdf:/ || $abbrev =~ /^rdfs:/;

    if ($abbrev =~ /^bffi:/) {
        $self->{stats}{kept}++;
        return $self->_expand($abbrev);
    }

    my $r = $self->{rename};
    my $target = $r->{properties}{$abbrev}
              || $r->{subproperties}{$abbrev}
              || $r->{classes}{$abbrev};   # some object-valued props are duals

    if ($target) {
        $self->{stats}{renamed}++;
        return $self->_expand($target);
    }

    $self->{stats}{dropped}++;
    $self->{stats}{dropped_terms}{$abbrev}++;
    return undef;
}

sub _map_class {
    my ($self, $uri, $fallback) = @_;

    # bf:Work is equivalent to the generic bffi:BibframeWork in the ontology,
    # but the projected 4-level graph uses the FRBR bffi:Work.
    return $BFFI . 'Work' if _canon_uri($uri) eq $BF . 'Work';

    my $abbrev = $self->_abbrev($uri);
    my $target = $self->{rename}{classes}{$abbrev};
    return $self->_expand($target) if $target;
    return $fallback ? $self->_expand($fallback) : undef;
}

sub _abbrev {
    my ($self, $uri) = @_;
    return $uri unless defined $uri;
    return $uri unless $uri =~ m{^https?://};
    $uri = _canon_uri($uri);

    for my $prefix (sort { length($NS{$b}) <=> length($NS{$a}) } keys %NS) {
        my $base = $NS{$prefix};
        if (index($uri, $base) == 0) {
            return "$prefix:" . substr($uri, length($base));
        }
    }
    return $uri;
}

# Expand a prefixed bffi: term to its full URI; pass through non-bffi terms.
sub _expand {
    my ($self, $term) = @_;
    return $term unless defined $term;
    return $BFFI . substr($term, 5) if $term =~ /^bffi:/;
    return $term;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _core_subjects {
    my ($self, $by_subject) = @_;

    my (@works, @instances, @items);
    for my $subject (keys %$by_subject) {
        for my $t (@{ $by_subject->{$subject} }) {
            next unless $t->{predicate} eq 'rdf:type';
            next unless ($t->{object_type} || '') eq 'uri';
            my $class = _canon_uri($t->{object});
            push @works,     $subject if $class eq $BF . 'Work';
            push @instances, $subject if $class eq $BF . 'Instance';
            push @items,     $subject if $class eq $BF . 'Item';
        }
    }

    return (
        _prefer(\@works,     qr{/resources/works/}),
        _prefer(\@instances, qr{/resources/instances/}),
        _prefer(\@items,     qr{/resources/items/}),
    );
}

sub _prefer {
    my ($list, $re) = @_;
    for my $uri (@$list) {
        return $uri if $uri =~ $re;
    }
    return $list->[0];
}

sub _derive_id {
    my ($self, $work, $instance) = @_;

    for my $uri ($work, $instance) {
        next unless $uri;
        return $1 if $uri =~ m{/resources/(?:works|instances|items)/([^/#]+)};
    }
    for my $uri ($work, $instance) {
        next unless $uri;
        (my $path = $uri) =~ s/#.*$//;
        return $1 if $path =~ m{([^/]+)$};
    }
    my $seed = join '|', grep { defined } ($work, $instance);
    return substr(sha1_hex($seed), 0, 16);
}

sub _mint {
    my ($self, $axis, $id) = @_;
    return $self->{base_uri} . $axis . '/' . $id;
}

sub _type {
    my ($subject, $class) = @_;
    return {
        subject     => $subject,
        predicate   => 'rdf:type',
        object      => $class,
        object_type => 'uri',
    };
}

sub _uri {
    my ($subject, $predicate, $object) = @_;
    return {
        subject     => $subject,
        predicate   => $predicate,
        object      => $object,
        object_type => 'uri',
    };
}

sub _copy {
    my ($t, $subject, $predicate, $uri_map) = @_;

    my $object = $t->{object};
    if (($t->{object_type} || '') eq 'uri' && $uri_map && $uri_map->{$object}) {
        $object = $uri_map->{$object};
    }

    return {
        subject     => $subject,
        predicate   => $predicate,
        object      => $object,
        object_type => $t->{object_type} || 'literal',
        ($t->{lang}     ? (lang     => $t->{lang})     : ()),
        ($t->{datatype} ? (datatype => $t->{datatype}) : ()),
    };
}

# The LoC local name of a predicate, given either a full URI or a prefixed name.
sub _loc_local {
    my ($pred) = @_;
    return undef unless defined $pred;
    $pred = _canon_uri($pred);
    if ($pred =~ m{^https?://[^/]+/ontologies/(?:bibframe|bflc)/(.+)$}) {
        return $1;
    }
    if ($pred =~ m{^(?:bf|bflc):(.+)$}) {
        return $1;
    }
    return undef;
}

# The plugin's store writes bf:/bflc: predicate URIs with a '#' fragment
# (SemanticStore::_expand_predicate_uri), while the ontology and the generated
# rename table use the '/' path form. Normalise the '#' fragment form to the
# path form so both are recognised identically.
sub _canon_uri {
    my ($uri) = @_;
    return $uri unless defined $uri;
    $uri =~ s{^http://id\.loc\.gov/ontologies/bibframe#}{http://id.loc.gov/ontologies/bibframe/};
    $uri =~ s{^http://id\.loc\.gov/ontologies/bflc#}{http://id.loc.gov/ontologies/bflc/};
    return $uri;
}

sub _is_loc_ns {
    my ($term) = @_;
    return 0 unless defined $term;
    $term = _canon_uri($term);
    return 1 if $term =~ m{^\Q$BF\E} || $term =~ m{^\Q$BFLC\E};
    return 1 if $term =~ m{^bf:} || $term =~ m{^bflc:};
    return 0;
}

1;
