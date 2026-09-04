package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use Search::Elasticsearch;
use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex

=head1 DESCRIPTION

Phase 12: Syncs bibliographic data from the hybrid storage layer to
Elasticsearch.

ES is a derived search index, never the source of truth. Documents are built
from the summary tables (fast) plus targeted core-table reads. Config is
plugin-specific (decoupled from Koha's own Elasticsearch) and read from the
koha-conf.xml C<bibframe_manager> stanza, environment variables, or constructor
arguments (highest priority).

Configuration keys (koha-conf.xml / env BIBFRAME_ES_*):
    es_server   - e.g. http://localhost:9200 (default)
    es_index    - index/alias name (default 'bibframe_entities')
    es_username - optional basic-auth user
    es_password - optional basic-auth password

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        es_server   => $args{es_server},
        es_index    => $args{es_index},
        es_username => $args{es_username},
        es_password => $args{es_password},
        es_enabled  => $args{es_enabled},
        es_model    => $args{es_model},
    };
    bless($self, $class);
    return $self;
}

sub dbh {
    return C4::Context->dbh;
}

# Resolves connection config with precedence: constructor > env > koha-conf.
sub _server {
    my ($self) = @_;
    return $self->{es_server}
        || $ENV{BIBFRAME_ES_SERVER}
        || (C4::Context->config('bibframe_manager') || {})->{es_server}
        || 'http://localhost:9200';
}

sub _index {
    my ($self, $model) = @_;

    $model ||= $self->_model();

    # An explicit/configured index name is used verbatim (no model suffix).
    return $self->{es_index} if defined $self->{es_index};
    return $ENV{BIBFRAME_ES_INDEX} if defined $ENV{BIBFRAME_ES_INDEX};

    my $conf = C4::Context->config('bibframe_manager');
    my $prefix = ($conf && $conf->{es_index})
        ? $conf->{es_index}
        : $self->_config_index_prefix();

    # Otherwise namespace per model so loc-3 / wemi-4 / loc-raw can coexist.
    return "${prefix}_${model}";
}

sub _config_index_prefix {
    my ($self) = @_;
    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get();
    return $cfg->{index_prefix} || 'bibframe_entities';
}

sub _model {
    my ($self) = @_;

    return $self->{es_model} if defined $self->{es_model};

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get();
    my $model = $cfg->{model} || 'loc-3';

    # Allow override via env / constructor
    my $env = $ENV{BIBFRAME_ES_MODEL};
    $model = $env if defined $env && length $env;

    $self->{es_model} = $model;
    return $model;
}

=head2 sync_enabled

    my $enabled = $self->sync_enabled();

Returns true when ES sync should be performed. Controlled by the plugin's
es_enabled config (koha-conf.xml bibframe_manager stanza) or the
BIBFRAME_ES_ENABLED env var; disabled (false) by default so the external
Elasticsearch dependency never breaks ordinary storage.

=cut

sub sync_enabled {
    my ($self) = @_;

    return 1 if defined $self->{es_enabled};

    my $env = $ENV{BIBFRAME_ES_ENABLED};
    return 1 if defined $env && $env =~ /^(1|true|yes|on)$/i;

    my $conf = C4::Context->config('bibframe_manager');
    return 1 if $conf && $conf->{es_enabled}
        && $conf->{es_enabled} =~ /^(1|true|yes|on)$/i;

    return 0;
}

sub _es_auth {
    my ($self) = @_;

    my $user = $self->{es_username} || $ENV{BIBFRAME_ES_USERNAME};
    my $pass = $self->{es_password} || $ENV{BIBFRAME_ES_PASSWORD};

    my $conf = C4::Context->config('bibframe_manager') || {};
    $user ||= $conf->{es_username};
    $pass ||= $conf->{es_password};

    return ($user, $pass);
}

=head1 PUBLIC METHODS

=head2 client

    my $es = $self->client();

Returns a lazy Search::Elasticsearch HTTP client.

=cut

sub client {
    my ($self) = @_;

    return $self->{_client} if $self->{_client};

    my ($user, $pass) = $self->_es_auth;

    my %opts = ( nodes => [ $self->_server() ] );
    if ($user) {
        $opts{http_auth} = [ $user, $pass ];
    }

    $self->{_client} = Search::Elasticsearch->new(%opts);
    return $self->{_client};
}

=head2 ensure_index

    $self->ensure_index();

Creates the index and mapping if it does not already exist. Idempotent.

=cut

sub ensure_index {
    my ($self) = @_;

    my $es = $self->client();
    my $index = $self->_index();

    my $created = 0;
    try {
        my $exists = $es->indices->exists(index => $index);
        if (!$exists) {
            $es->indices->create(
                index => $index,
                body  => {
                    mappings => $self->_mapping(),
                },
            );
            $created = 1;
        }
    } catch {
        warn "ensure_index failed: $_";
    };

    return $created;
}

sub _mapping {
    my ($self) = @_;

    my $model = $self->_model();

    my $props = {
        biblio_id  => { type => 'long' },
        work       => {
            type => 'object',
            properties => {
                uri      => { type => 'keyword' },
                label    => { type => 'text', fields => { keyword => { type => 'keyword' } } },
                type     => { type => 'keyword' },
                language => { type => 'keyword' },
                subjects => {
                    type => 'nested',
                    properties => {
                        term   => { type => 'text' },
                        type   => { type => 'keyword' },
                        source => { type => 'keyword' },
                    },
                },
            },
        },
        agents => {
            type => 'nested',
            properties => {
                name     => { type => 'text' },
                role     => { type => 'keyword' },
                agent_id => { type => 'long' },
            },
        },
        manifestation => {
            type => 'object',
            properties => {
                publisher   => { type => 'text' },
                date        => { type => 'keyword' },
                date_sort   => { type => 'date' },
                formats     => { type => 'keyword' },
                identifiers => {
                    type => 'nested',
                    properties => {
                        type  => { type => 'keyword' },
                        value => { type => 'keyword' },
                    },
                },
            },
        },
        component_parts => {
            type => 'nested',
            properties => {
                host_title => { type => 'text' },
                host_issn  => { type => 'keyword' },
                volume     => { type => 'text' },
            },
        },
        suggest => {
            type => 'completion',
            contexts => [],
        },
    };

    # wemi-4: derived Expression nodes under work.expressions
    if ($model eq 'wemi-4') {
        $props->{work}{properties}{expressions} = {
            type => 'nested',
            properties => {
                uri             => { type => 'keyword' },
                title           => { type => 'text' },
                main_title      => { type => 'text' },
                language        => { type => 'keyword' },
                original_language => { type => 'keyword' },
                edition         => { type => 'text' },
                content_type    => { type => 'keyword' },
            },
        };
    }

    # loc-raw: entity-oriented docs carry the resource type/uri
    if ($model eq 'loc-raw') {
        $props->{resource_uri}    = { type => 'keyword' };
        $props->{resource_type}   = { type => 'keyword' };
        $props->{resource_label}  = { type => 'text' };
    }

    return { properties => $props };
}

=head2 build_document

    my $doc = $self->build_document($biblio_id);

Assembles the C<record_entities> document for a biblio from the summary and
core tables. Returns a hashref, or undef if no stored data exists.

=cut

sub build_document {
    my ($self, $biblio_id) = @_;

    return undef unless $biblio_id;

    my $model = $self->_model();

    if ($model eq 'loc-raw') {
        # loc-raw builds multiple entity documents; select the first and let
        # callers use build_documents for the full entity set.
        my $docs = $self->build_documents($biblio_id);
        return $docs->[0];
    }

    my $work = $self->_work_data($biblio_id);
    return undef unless $work;

    my $doc = {
        biblio_id       => $biblio_id + 0,
        work            => $self->_map_work($work),
        agents          => $self->_agents_for_work($work->{resource_id}),
        manifestation   => $self->_manifestation_data($biblio_id),
        component_parts => $self->_component_parts_data($biblio_id),
    };

    $doc->{work}{subjects} = $self->_subjects_for_work($work->{resource_id});

    # wemi-4: derive the Expression level at index time from stored LoC triples
    if ($model eq 'wemi-4') {
        my $wemi_cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('wemi') || {};
        my $expr_key = ($wemi_cfg->{expression} || {})->{expression_key} || 'expressions';
        $doc->{work}{$expr_key} = $self->_derive_expressions($biblio_id);
    }

    $doc->{suggest} = $self->_build_suggest($doc);

    return $doc;
}

=head2 build_documents

    my $docs = $self->build_documents($biblio_id);

Returns a list of documents for a biblio. For the default (loc-3) and wemi-4
models this is a single flattened document. For loc-raw it is one document per
stored LoC entity (Work, Instance, Agent, Topic, Item, ...).

=cut

sub build_documents {
    my ($self, $biblio_id) = @_;

    return [] unless $biblio_id;

    my $model = $self->_model();

    if ($model eq 'loc-raw') {
        return $self->_loc_raw_documents($biblio_id);
    }

    my $doc = $self->build_document($biblio_id);
    return $doc ? [ $doc ] : [];
}

# loc-raw: one document per stored LoC entity belonging to the biblio graph.
# Preserves the original BIBFRAME entity structure (each entity indexed under
# its own URI). _id for these is the resource URI (handled by indexers).
sub _loc_raw_documents {
    my ($self, $biblio_id) = @_;

    return [] unless $biblio_id;

    my $sth = $self->dbh->prepare(
        "SELECT r.id, r.uri, r.resource_type, r.label, r.biblio_id,
                r.item_id
         FROM record_resources r
         WHERE r.biblio_id = ? OR r.id IN (
             SELECT target_resource_id FROM record_links l
             JOIN record_resources src ON src.id = l.source_resource_id
             WHERE src.biblio_id = ?
         )"
    );
    $sth->execute($biblio_id, $biblio_id);

    my @docs;
    while (my $row = $sth->fetchrow_hashref()) {
        push @docs, {
            biblio_id      => $row->{biblio_id} ? $row->{biblio_id} + 0 : undef,
            resource_uri   => $row->{uri},
            resource_type  => $row->{resource_type},
            resource_label => $row->{label},
            properties     => $self->_raw_properties($row->{id}),
            links          => $self->_raw_links($row->{id}),
        };
    }

    return \@docs;
}

sub _raw_properties {
    my ($self, $resource_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT property_key, value_text, value_lang
         FROM record_properties WHERE resource_id = ? ORDER BY sequence"
    );
    $sth->execute($resource_id);

    my @props;
    while (my $row = $sth->fetchrow_hashref()) {
        next unless defined $row->{value_text};
        push @props, {
            key  => $row->{property_key},
            value => $row->{value_text},
            ($row->{value_lang} ? (lang => $row->{value_lang}) : ()),
        };
    }
    return \@props;
}

sub _raw_links {
    my ($self, $resource_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT l.relationship_type, src.uri AS source_uri, tgt.uri AS target_uri
         FROM record_links l
         JOIN record_resources src ON src.id = l.source_resource_id
         JOIN record_resources tgt ON tgt.id = l.target_resource_id
         WHERE l.source_resource_id = ? OR l.target_resource_id = ?"
    );
    $sth->execute($resource_id, $resource_id);

    my @links;
    while (my $row = $sth->fetchrow_hashref()) {
        push @links, {
            relationship_type => $row->{relationship_type},
            source_uri        => $row->{source_uri},
            target_uri        => $row->{target_uri},
        };
    }
    return \@links;
}

# Derives Expression node(s) from the stored LoC 3-level graph and maps them
# onto the configured wemi.expression fields. No schema change: Expression is
# computed at index time.
sub _derive_expressions {
    my ($self, $biblio_id) = @_;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('wemi') || {};
    my $expr_cfg = $cfg->{expression} || {};
    return [] unless $expr_cfg->{enabled};

    my $field_map = $expr_cfg->{field_map} || {};

    # Get stored LoC 3-level triples, then derive 4-level WEMI
    my $gen = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BibframeGenerator->new();
    my $loc_triples = $gen->generate_triples(biblio_id => $biblio_id);
    return [] unless $loc_triples && @$loc_triples;

    my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
    my $wemi = $converter->derive_wemi_from_loc($loc_triples, base_uri => 'http://urn.fi/URN:NBN:fi:bib:');
    return [] unless $wemi && @$wemi;

    my $bffi_ns = 'http://urn.fi/URN:NBN:fi:schema:bffi:';

    # Find Expression subject(s)
    my %exprs;
    for my $t (@$wemi) {
        next unless $t->{predicate} =~ /rdf:type$/ && $t->{object_type} eq 'uri';
        if ($t->{object} eq "${bffi_ns}Expression") {
            $exprs{$t->{subject}} = { uri => $t->{subject} };
        }
    }

    my @subjects = keys %exprs;
    return [] unless @subjects;

    my @out;
    for my $subj (@subjects) {
        my $expr = $exprs{$subj};
        for my $t (@$wemi) {
            next unless $t->{subject} eq $subj;
            my $localname = _localname($t->{predicate});

            next unless exists $field_map->{$localname};
            my $key = $field_map->{$localname};
            next unless defined $t->{object};

            # Keep the first occurrence for scalar fields
            if (!exists $expr->{$key}) {
                $expr->{$key} = $t->{object};
            }
        }
        push @out, $expr;
    }

    return \@out;
}

sub _localname {
    my ($pred) = @_;
    ($pred) = $pred =~ m{[/#]([^/#]+)$};
    return defined $pred ? $pred : '';
}

# Maps the raw work summary row onto the configured work keys.
sub _map_work {
    my ($self, $work) = @_;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('work') || {};
    my $out = {};

    for my $doc_key (keys %$cfg) {
        next if ref($cfg->{$doc_key}) eq 'HASH';   # nested sections handled elsewhere
        my $src = $cfg->{$doc_key};
        if ($doc_key eq 'uri') {
            $out->{$doc_key} = $work->{uri} if $work->{uri};
        } elsif ($doc_key eq 'label') {
            $out->{$doc_key} = $work->{label} if $work->{label};
        } elsif (exists $work->{summary}{$src}) {
            $out->{$doc_key} = $work->{summary}{$src};
        }
    }

    # Fall back to the resource label when the summary label is not set
    $out->{label} ||= $work->{label};

    return $out;
}

sub _build_suggest {
    my ($self, $doc) = @_;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('suggest') || {};
    my $weight = $cfg->{weight} // 10;

    my @input;
    for my $path (@{$cfg->{input_fields} || []}) {
        my $val = $self->_deref_path($doc, $path);
        push @input, $val if defined $val && length $val;
    }

    return { input => \@input, weight => $weight };
}

# Dereferences a dotted path like 'work.label' or 'agents.name' (last segment
# aggregates over arrays) within the built document.
sub _deref_path {
    my ($self, $doc, $path) = @_;

    my @segs = split /\./, $path;
    my $node = $doc;
    for (my $i = 0; $i < @segs; $i++) {
        my $seg = $segs[$i];
        last unless ref($node) eq 'HASH' && exists $node->{$seg};
        $node = $node->{$seg};
    }

    # If we landed on a hash, aggregate scalar-valued array item fields
    if (ref($node) eq 'ARRAY') {
        my @vals;
        for my $item (@$node) {
            push @vals, $item if !ref($item) && defined $item;
        }
        return join(' ', @vals);
    }

    return $node;
}

=head2 index_document

    $self->index_document($biblio_id);

Builds and indexes (upserts) the document for a biblio.

=cut

sub index_document {
    my ($self, $biblio_id) = @_;

    my $docs = $self->build_documents($biblio_id);
    return 0 unless $docs && @$docs;

    $self->ensure_index();

    my $es = $self->client();
    my $index = $self->_index();

    my $count = 0;
    for my $doc (@$docs) {
        my $id = $self->_doc_id($doc, $biblio_id);
        $es->index(index => $index, id => $id, body => $doc);
        $count++;
    }

    return $count;
}

=item C<_doc_id>

Chooses the document _id: for loc-raw use the resource URI, otherwise the
biblio-scoped id.

=cut

sub _doc_id {
    my ($self, $doc, $biblio_id) = @_;

    if ($self->_model() eq 'loc-raw' && $doc->{resource_uri}) {
        return 'entity_' . $doc->{resource_uri};
    }
    return 'biblio_' . $biblio_id;
}

=head2 index_biblios

    my $count = $self->index_biblios(\@biblio_ids);

Bulk-indexes a list of biblio ids. Returns the number indexed.

=cut

sub index_biblios {
    my ($self, $biblio_ids) = @_;

    return 0 unless $biblio_ids && @$biblio_ids;

    $self->ensure_index();

    my $es = $self->client();
    my $index = $self->_index();

    my @bulk;
    for my $id (@$biblio_ids) {
        my $docs = $self->build_documents($id);
        next unless $docs && @$docs;
        for my $doc (@$docs) {
            my $doc_id = $self->_doc_id($doc, $id);
            push @bulk,
                { index => { _index => $index, _id => $doc_id } },
                $doc;
        }
    }

    return 0 unless @bulk;

    $es->bulk(body => \@bulk);
    return scalar(@bulk) / 2;
}

=head2 delete_document

    $self->delete_document($biblio_id);

Removes a biblio's document from the index (errors are swallowed so a missing
doc does not fail the caller).

=cut

sub delete_document {
    my ($self, $biblio_id) = @_;

    # loc-raw stores one document per entity (not biblio-scoped), so remove
    # them all by biblio_id rather than a single fixed id.
    if ($self->_model() eq 'loc-raw') {
        try {
            $self->client()->delete_by_query(
                index   => $self->_index(),
                body    => { query => { term => { biblio_id => $biblio_id + 0 } } },
            );
        } catch {
            warn "delete_by_query for biblio $biblio_id: $_";
        };
        return 1;
    }

    try {
        $self->client()->delete(
            index => $self->_index(),
            id    => 'biblio_' . $biblio_id,
        );
    } catch {
        warn "delete_document $biblio_id: $_";
    };

    return 1;
}

=head2 sync_biblio

    $self->sync_biblio($biblio_id);

Convenience: (re)index a single biblio.

=cut

sub sync_biblio {
    my ($self, $biblio_id) = @_;
    return $self->index_document($biblio_id);
}

=head2 rebuild_all

    my $count = $self->rebuild_all();

Reindexes every biblio with stored semantic data. Returns the number indexed.

=cut

sub rebuild_all {
    my ($self) = @_;

    my $sth = $self->dbh->prepare(
        'SELECT DISTINCT biblio_id FROM record_resources WHERE biblio_id IS NOT NULL'
    );
    $sth->execute();

    my @ids;
    while (my $row = $sth->fetchrow_hashref()) { push @ids, $row->{biblio_id}; }

    return $self->index_biblios(\@ids);
}

=head1 PRIVATE METHODS

=cut

# Returns work summary row + its resource_id for a biblio.
sub _work_data {
    my ($self, $biblio_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT ws.*, r.uri AS resource_uri, r.label AS resource_label
         FROM record_work_summary ws
         JOIN record_resources r ON r.id = ws.resource_id
         WHERE ws.biblio_id = ? LIMIT 1"
    );
    $sth->execute($biblio_id);
    my $row = $sth->fetchrow_hashref();

    return undef unless $row;

    return {
        summary     => $row,
        resource_id => $row->{resource_id},
        label       => $row->{resource_label},
        uri         => $row->{resource_uri},
    };
}

sub _agents_for_work {
    my ($self, $work_resource_id) = @_;

    return [] unless $work_resource_id;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('agents') || {};
    my $rels = $cfg->{relationship_types} || ['creator', 'contributor'];
    my $placeholders = join ',', ('?') x @$rels;

    # First listed relationship type maps to role 'aut'
    my %role_for;
    $role_for{$rels->[0]} = 'aut';
    for my $rel (@$rels) { $role_for{$rel} ||= 'ctb'; }

    my $sth = $self->dbh->prepare(
        "SELECT r.id, r.label, l.relationship_type
         FROM record_links l
         JOIN record_resources r ON r.id = l.target_resource_id
         WHERE l.source_resource_id = ?
           AND l.relationship_type IN ($placeholders)
         ORDER BY l.sequence"
    );
    $sth->execute($work_resource_id, @$rels);

    my $fields = $cfg->{fields} || { name => 'label', role => 'role', agent_id => 'id' };

    my @agents;
    while (my $row = $sth->fetchrow_hashref()) {
        my %agent;
        for my $doc_key (keys %$fields) {
            my $src = $fields->{$doc_key};
            if ($src eq 'role') {
                $agent{$doc_key} = $role_for{$row->{relationship_type}} || 'ctb';
            } elsif (exists $row->{$src}) {
                $agent{$doc_key} = $row->{$src};
            }
        }
        push @agents, \%agent;
    }
    return \@agents;
}

sub _subjects_for_work {
    my ($self, $work_resource_id) = @_;

    return [] unless $work_resource_id;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('subjects') || {};
    my $rel = $cfg->{relationship_type} || 'subject';
    my $fields = $cfg->{fields} || { term => 'label', type => 'resource_type', source => 'source' };

    my $sth = $self->dbh->prepare(
        "SELECT r.label, r.resource_type, p.value_text AS source
         FROM record_links l
         JOIN record_resources r ON r.id = l.target_resource_id
         LEFT JOIN record_properties p
                ON p.resource_id = r.id AND p.property_key = 'source'
         WHERE l.source_resource_id = ?
           AND l.relationship_type = ?
         ORDER BY l.sequence"
    );
    $sth->execute($work_resource_id, $rel);

    my @subjects;
    while (my $row = $sth->fetchrow_hashref()) {
        my %subject;
        for my $doc_key (keys %$fields) {
            my $src = $fields->{$doc_key};
            next unless exists $row->{$src};
            $subject{$doc_key} = $row->{$src};
        }
        push @subjects, \%subject;
    }
    return \@subjects;
}

sub _manifestation_data {
    my ($self, $biblio_id) = @_;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('manifestation') || {};
    my $ids_cfg = $cfg->{identifiers} || {};

    my $sth = $self->dbh->prepare(
        "SELECT mis.* FROM record_instance_summary mis
         WHERE mis.biblio_id = ? LIMIT 1"
    );
    $sth->execute($biblio_id);
    my $row = $sth->fetchrow_hashref();

    return undef unless $row;

    my $doc = {};

    for my $doc_key (keys %$cfg) {
        next if ref($cfg->{$doc_key}) eq 'HASH';
        my $src = $cfg->{$doc_key};
        next unless exists $row->{$src};
        $doc->{$doc_key} = $row->{$src};
    }

    # formats aggregates carrier + media type (or any configured list)
    my @format_fields = grep { defined && $row->{$_} } grep { defined } ($row->{carrier_type}, $row->{media_type});
    $doc->{formats} = \@format_fields if @format_fields;

    # Identifiers from core properties, per config
    my $ids = $self->_identifiers($row->{resource_id}, $ids_cfg);
    $doc->{identifiers} = $ids if @$ids;

    return $doc;
}

sub _identifiers {
    my ($self, $resource_id, $cfg) = @_;

    return [] unless $resource_id;

    $cfg ||= {};
    my $type_field = $cfg->{type_field} || 'property_key';
    my $value_field = $cfg->{value_field} || 'value_text';
    my $match = $cfg->{property_key_match} || '~identifier';
    my $like = "%" . ($match =~ s/^~//r) . '%';

    my $sth = $self->dbh->prepare(
        "SELECT $type_field AS type, $value_field AS value
         FROM record_properties
         WHERE resource_id = ? AND property_key LIKE ?
         ORDER BY sequence"
    );
    $sth->execute($resource_id, $like);

    my @ids;
    while (my $row = $sth->fetchrow_hashref()) {
        next unless defined $row->{value} && length $row->{value};
        push @ids, { type => $row->{type}, value => $row->{value} };
    }
    return \@ids;
}

sub _component_parts_data {
    my ($self, $biblio_id) = @_;

    return [] unless $biblio_id;

    my $cfg = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping::get_section('component_parts') || {};
    my $limit = $cfg->{limit} || 100;
    my $fields = $cfg->{fields}
        || { host_title => 'host_title', host_issn => 'host_issn', volume => 'volume_designation' };

    # Build SELECT list from config field mappings (doc_key -> column)
    my @sel_cols;
    for my $doc_key (keys %$fields) {
        push @sel_cols, $fields->{$doc_key} . ' AS ' . $doc_key;
    }
    my $sel = join ', ', @sel_cols;

    my $sth = $self->dbh->prepare(
        "SELECT $sel
         FROM record_component_parts cp
         JOIN record_resources r ON r.id = cp.component_resource_id
         WHERE r.biblio_id = ? OR cp.host_resource_id IN (
             SELECT id FROM record_resources WHERE biblio_id = ?
         )
         LIMIT $limit"
    );
    $sth->execute($biblio_id, $biblio_id);

    my @parts;
    while (my $row = $sth->fetchrow_hashref()) {
        my %part;
        for my $doc_key (keys %$fields) {
            next unless defined $row->{$doc_key};
            $part{$doc_key} = $row->{$doc_key};
        }
        push @parts, \%part;
    }
    return \@parts;
}

1;
