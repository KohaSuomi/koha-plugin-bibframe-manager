package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryReader;

use strict;
use warnings;
use utf8;
use C4::Context;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryReader

=head1 DESCRIPTION

Phase 13: Serves the API read side from the typed summary tables
(record_work_summary, record_instance_summary, record_agent_summary) instead
of biblio_metadata.

The summary tables are derived from the canonical core storage layer and are
rebuilt whenever core rows change (SummaryRebuilder), so reads here never hit
biblio_metadata. This module is the fast, typed read accessor for the sync
store's API.

=cut

sub new {
    my ($class) = @_;
    my $self = {};
    bless($self, $class);
    return $self;
}

sub dbh {
    return C4::Context->dbh;
}

=head2 get_for_biblio

    my $data = $reader->get_for_biblio($biblio_id);

Returns a hashref with the Work, Instances and Agents for a biblio, sourced
from the summary tables:

    {
        work       => { id, resource_id, title, title_normalized, language,
                        work_type, original_language, original_resource_id,
                        original_external_id, original_external_source,
                        contributor_count, subject_count, instance_count,
                        uri },
        instances  => [ { resource_id, work_resource_id, publisher_name,
                          publication_place, publication_date,
                          publication_date_sort, instance_type, media_type,
                          carrier_type, extent, uri } ],
        agents     => [ { id, name, agent_type, role, name_normalized } ],
    }

Returns an empty work hashref (and empty arrays) when there is no stored
work summary for the biblio.

=cut

sub get_for_biblio {
    my ($self, $biblio_id) = @_;

    return { work => {}, instances => [], agents => [] } unless $biblio_id;

    my $work = $self->get_work_for_biblio($biblio_id);
    my $instances = $self->get_instances_for_biblio($biblio_id);

    my @agents;
    if ($work && $work->{resource_id}) {
        @agents = @{ $self->get_agents_for_work($work->{resource_id}) };
    }

    return {
        work      => $work || {},
        instances => $instances,
        agents    => \@agents,
    };
}

=head2 get_work_for_biblio

    my $work = $reader->get_work_for_biblio($biblio_id);

Returns the record_work_summary row (plus the resource uri/label) for the
biblio, or undef.

=cut

sub get_work_for_biblio {
    my ($self, $biblio_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT ws.*, r.uri
         FROM record_work_summary ws
         JOIN record_resources r ON r.id = ws.resource_id
         WHERE ws.biblio_id = ?
         ORDER BY ws.instance_count DESC
         LIMIT 1"
    );
    $sth->execute($biblio_id);
    return $sth->fetchrow_hashref();
}

=head2 get_work

    my $work = $reader->get_work($resource_id);

Returns the record_work_summary row (plus uri) for a Work resource, or undef.

=cut

sub get_work {
    my ($self, $resource_id) = @_;

    return unless $resource_id;

    my $sth = $self->dbh->prepare(
        "SELECT ws.*, r.uri
         FROM record_work_summary ws
         JOIN record_resources r ON r.id = ws.resource_id
         WHERE ws.resource_id = ?
         LIMIT 1"
    );
    $sth->execute($resource_id);
    return $sth->fetchrow_hashref();
}

=head2 get_instances_for_biblio

    my $instances = $reader->get_instances_for_biblio($biblio_id);

Returns all record_instance_summary rows (plus uri) for a biblio, ordered by
publication date.

=cut

sub get_instances_for_biblio {
    my ($self, $biblio_id) = @_;

    my @instances;
    return \@instances unless $biblio_id;

    my $sth = $self->dbh->prepare(
        "SELECT mis.*, r.uri
         FROM record_instance_summary mis
         JOIN record_resources r ON r.id = mis.resource_id
         WHERE mis.biblio_id = ?
         ORDER BY mis.publication_date_sort IS NULL, mis.publication_date_sort"
    );
    $sth->execute($biblio_id);
    while (my $row = $sth->fetchrow_hashref()) {
        push @instances, $row;
    }
    return \@instances;
}

=head2 get_instance

    my $instance = $reader->get_instance($resource_id);

Returns a record_instance_summary row (plus uri) for an Instance resource, or
undef.

=cut

sub get_instance {
    my ($self, $resource_id) = @_;

    return unless $resource_id;

    my $sth = $self->dbh->prepare(
        "SELECT mis.*, r.uri
         FROM record_instance_summary mis
         JOIN record_resources r ON r.id = mis.resource_id
         WHERE mis.resource_id = ?
         LIMIT 1"
    );
    $sth->execute($resource_id);
    return $sth->fetchrow_hashref();
}

=head2 get_agents_for_work

    my $agents = $reader->get_agents_for_work($work_resource_id);

Returns agent names for a Work, sourced from record_agent_summary joined via
record_links (creator/contributor relationships). Each agent includes a role
(creator -> 'aut', else 'ctb') and its agent type.

=cut

sub get_agents_for_work {
    my ($self, $work_resource_id) = @_;

    my @agents;
    return \@agents unless $work_resource_id;

    my $sth = $self->dbh->prepare(
        "SELECT a.resource_id, a.name, a.agent_type, a.name_normalized,
                l.relationship_type
         FROM record_links l
         JOIN record_agent_summary a ON a.resource_id = l.target_resource_id
         WHERE l.source_resource_id = ?
           AND l.relationship_type IN ('creator', 'contributor')
         ORDER BY l.sequence"
    );
    $sth->execute($work_resource_id);

    while (my $row = $sth->fetchrow_hashref()) {
        my $role = $row->{relationship_type} eq 'creator' ? 'aut' : 'ctb';
        push @agents, {
            id               => $row->{resource_id},
            resource_id      => $row->{resource_id},
            name             => $row->{name},
            name_normalized  => $row->{name_normalized},
            agent_type       => $row->{agent_type},
            role             => $role,
        };
    }
    return \@agents;
}

1;
