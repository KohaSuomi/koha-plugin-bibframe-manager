package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::ComponentPartsSync;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use JSON;
use C4::Context;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::ComponentPartsSync

=head1 DESCRIPTION

Phase 9: Populates the materialized component-parts summary table
(record_component_parts) from the canonical record_links table.

Component part relationships (MARC 773/774 <-> BIBFRAME partOf/hasPart) are
the one query pattern the generic EAV store handles poorly, so the hybrid plan
materializes them into a typed table. This module keeps that table in sync.

Relationship types that denote a component/host containment are:
    partOf        - component -> host (MARC 773)
    hasPart       - host -> component (MARC 774)

Other serial-related relationships (precededBy, succeededBy, supplement,
etc.) are not materialized here because they are not a containment pattern.

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

# Relationship types that express containment between a component and a host.
my %CONTAINMENT_RELATIONS = map { $_ => 1 } qw(partOf hasPart supplement supplementTo);

=head1 PUBLIC METHODS

=head2 sync_all

    $sync->sync_all();

Rebuilds the entire record_component_parts table from record_links.

=cut

sub sync_all {
    my ($self) = @_;

    my $dbh = $self->dbh;

    my $count = 0;
    eval {
        $dbh->begin_work();

        $dbh->do('TRUNCATE TABLE record_component_parts');

        $count = $self->_sync_links();

        $dbh->commit();
    };

    if ($@) {
        $dbh->rollback();
        die "Component parts sync failed: $@";
    }

    return $count;
}

=head2 sync_for_resource

    $sync->sync_for_resource($resource_id);

Rebuilds component-part rows where the given resource acts as a component or
a host.

=cut

sub sync_for_resource {
    my ($self, $resource_id) = @_;

    my $dbh = $self->dbh;

    $dbh->do(
        'DELETE FROM record_component_parts
         WHERE component_resource_id = ? OR host_resource_id = ?',
        undef, $resource_id, $resource_id
    );

    return $self->_sync_links_where(
        '(l.source_resource_id = ? OR l.target_resource_id = ?)',
        $resource_id, $resource_id
    );
}

=head1 PRIVATE METHODS

=cut

# Reads all containment links and materializes matching record_component_parts rows.
sub _sync_links {
    my ($self) = @_;

    return $self->_sync_links_where('1=1');
}

sub _sync_links_where {
    my ($self, $where, @args) = @_;

    my $dbh = $self->dbh;

    my $sth = $dbh->prepare(
        "SELECT l.id, l.source_resource_id, l.target_resource_id,
                l.relationship_type, l.properties_json,
                src.uri AS source_uri, src.label AS source_label, src.resource_type AS source_type,
                tgt.uri AS target_uri, tgt.label AS target_label, tgt.resource_type AS target_type
         FROM record_links l
         JOIN record_resources src ON src.id = l.source_resource_id
         JOIN record_resources tgt ON tgt.id = l.target_resource_id
         WHERE $where"
    );
    $sth->execute(@args);

    my $insert = $dbh->prepare(
        "INSERT INTO record_component_parts
             (component_resource_id, host_resource_id, relationship_type,
              relationship_label, relationship_info, volume_designation,
              host_title, host_issn, host_control_number, host_uri, source_marc_tag)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    );

    my $count = 0;
    while (my $link = $sth->fetchrow_hashref()) {
        my ($component_id, $host_id, $rel_type, $direction);
        my $props = $self->_decode_props($link->{properties_json});

        if ($link->{relationship_type} eq 'partOf') {
            # component -> host
            $component_id = $link->{source_resource_id};
            $host_id      = $link->{target_resource_id};
            $rel_type     = 'partOf';
            $direction    = 'component_to_host';
        } elsif ($link->{relationship_type} eq 'hasPart') {
            # host -> component (reciprocal)
            $component_id = $link->{target_resource_id};
            $host_id      = $link->{source_resource_id};
            $rel_type     = 'partOf';          # store in canonical component->host direction
            $direction    = 'host_to_component';
        } elsif ($link->{relationship_type} eq 'supplement') {
            $component_id = $link->{source_resource_id};
            $host_id      = $link->{target_resource_id};
            $rel_type     = 'supplement';
            $direction    = 'component_to_host';
        } elsif ($link->{relationship_type} eq 'supplementTo') {
            $component_id = $link->{target_resource_id};
            $host_id      = $link->{source_resource_id};
            $rel_type     = 'supplement';
            $direction    = 'host_to_component';
        } else {
            next;
        }

        # Determine component/host labels and URIs based on direction
        my ($component_label, $host_label, $host_uri);
        if ($direction eq 'component_to_host') {
            $component_label = $link->{source_label};
            $host_label      = $link->{target_label};
            $host_uri        = $link->{target_uri};
        } else {
            $component_label = $link->{target_label};
            $host_label      = $link->{source_label};
            $host_uri        = $link->{source_uri};
        }

        my $host_title = $props->{hostTitle} || $host_label;

        $insert->execute(
            $component_id,
            $host_id,
            $rel_type,
            $props->{relationshipLabel},
            $props->{relationshipInfo},
            $props->{volumeDesignation} || $props->{volume},
            $host_title,
            $props->{hostIssn},
            $props->{hostControlNumber},
            $props->{hostUri} || $host_uri,
            $props->{sourceMarcTag},
        );
        $count++;
    }

    return $count;
}

sub _decode_props {
    my ($self, $json) = @_;

    return {} unless $json;

    my $decoded = eval { decode_json($json) };
    return {} if $@ || ref($decoded) ne 'HASH';

    return $decoded;
}

1;
