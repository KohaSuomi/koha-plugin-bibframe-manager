package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryRebuilder;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use C4::Context;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryRebuilder

=head1 DESCRIPTION

Rebuilds the summary tables (record_work_summary, record_manif_summary,
record_agent_summary) from the canonical core storage layer
(record_resources, record_properties, record_links).

The summary tables are derived, not authoritative. They are rebuilt whenever
the core tables change so that common read queries stay fast without doing
EAV pivots on every request.

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

=head1 PUBLIC METHODS

=head2 rebuild_all

    $rebuilder->rebuild_all();

Wipes and rebuilds all three summary tables in a single transaction.

=cut

sub rebuild_all {
    my ($self) = @_;

    my $dbh = $self->dbh;

    my $result = {
        work_summary => 0,
        manifest_summary => 0,
        agent_summary => 0,
    };

    eval {
        $dbh->begin_work();

        $dbh->do('TRUNCATE TABLE record_work_summary');
        $dbh->do('TRUNCATE TABLE record_manif_summary');
        $dbh->do('TRUNCATE TABLE record_agent_summary');

        $result->{work_summary} = $self->_rebuild_work_summary();
        $result->{manifest_summary} = $self->_rebuild_manif_summary();
        $result->{agent_summary} = $self->_rebuild_agent_summary();

        $dbh->commit();
    };

    if ($@) {
        $dbh->rollback();
        die "Summary rebuild failed: $@";
    }

    return $result;
}

=head2 rebuild_work_summary

    $rebuilder->rebuild_work_summary($resource_id);

Rebuilds the work_summary row for a single Work resource.

=cut

sub rebuild_work_summary {
    my ($self, $resource_id) = @_;

    my $dbh = $self->dbh;

    $dbh->do(
        'DELETE FROM record_work_summary WHERE resource_id = ?',
        undef, $resource_id
    );

    $self->_rebuild_work_summary($resource_id);
}

=head2 rebuild_manif_summary

    $rebuilder->rebuild_manif_summary($resource_id);

Rebuilds the manifest_summary row for a single Manifestation resource.

=cut

sub rebuild_manif_summary {
    my ($self, $resource_id) = @_;

    my $dbh = $self->dbh;

    $dbh->do(
        'DELETE FROM record_manif_summary WHERE resource_id = ?',
        undef, $resource_id
    );

    $self->_rebuild_manif_summary($resource_id);
}

=head2 rebuild_agent_summary

    $rebuilder->rebuild_agent_summary($resource_id);

Rebuilds the agent_summary row for a single Agent resource.

=cut

sub rebuild_agent_summary {
    my ($self, $resource_id) = @_;

    my $dbh = $self->dbh;

    $dbh->do(
        'DELETE FROM record_agent_summary WHERE resource_id = ?',
        undef, $resource_id
    );

    $self->_rebuild_agent_summary($resource_id);
}

=head1 PRIVATE METHODS

=cut

sub _rebuild_work_summary {
    my ($self, $only_resource_id) = @_;

    my $dbh = $self->dbh;

    my $where = $only_resource_id
        ? 'AND id = ?'
        : '';

    my $sth = $dbh->prepare(
        "SELECT id, biblio_id, label
         FROM record_resources
         WHERE resource_type = 'Work' $where"
    );

    if ($only_resource_id) {
        $sth->execute($only_resource_id);
    } else {
        $sth->execute();
    }

    my $insert = $dbh->prepare(
        "INSERT INTO record_work_summary
             (resource_id, biblio_id, title, title_normalized, language,
              work_type, original_language, original_resource_id, original_pending,
              contributor_count, subject_count, manifestation_count)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    );

    my $count = 0;
    while (my $work = $sth->fetchrow_hashref()) {
        my $rid = $work->{id};

        my $props = $self->_properties_for($rid);
        my $title = $props->{title}->[0] || $work->{label} || '';
        my $work_type = $props->{work_type}->[0];
        my $original_language = $props->{originalLanguage}->[0];

        # Work-level language defaults to the original language when present
        my $language = $original_language || $props->{languageOfExpression}->[0];

        # Determine the local original expression (language == original and not a translation)
        my ($original_resource_id, $original_pending);
        if ($original_language) {
            my ($orig_id) = $self->_find_original_expression($rid, $original_language);
            $original_resource_id = $orig_id;
            $original_pending = $orig_id ? 0 : 1;
        } else {
            $original_pending = 0;
        }

        # Count linked entities
        my ($contributor_count, $subject_count, $manifestation_count) =
            $self->_count_linked($rid);

        $insert->execute(
            $rid,
            $work->{biblio_id},
            $title,
            $self->_normalize_title($title),
            $language,
            $work_type,
            $original_language,
            $original_resource_id,
            $original_pending,
            $contributor_count,
            $subject_count,
            $manifestation_count,
        );
        $count++;
    }

    return $count;
}

sub _rebuild_manif_summary {
    my ($self, $only_resource_id) = @_;

    my $dbh = $self->dbh;

    my $where = $only_resource_id
        ? 'AND id = ?'
        : '';

    my $sth = $dbh->prepare(
        "SELECT id, biblio_id
         FROM record_resources
         WHERE resource_type IN ('Manifestation', 'Instance') $where"
    );

    if ($only_resource_id) {
        $sth->execute($only_resource_id);
    } else {
        $sth->execute();
    }

    my $insert = $dbh->prepare(
        "INSERT INTO record_manif_summary
             (resource_id, work_resource_id, biblio_id,
              publisher_name, publication_place, publication_date, publication_date_sort,
              manifestation_type, media_type, carrier_type, extent)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    );

    my $count = 0;
    while (my $manif = $sth->fetchrow_hashref()) {
        my $rid = $manif->{id};

        my $props = $self->_properties_for($rid);

        my $date = $props->{publicationDate}->[0];
        my $date_sort = $self->_parse_date_for_sort($date);

        my $work_resource_id = $self->_derive_work_resource($rid);

        $insert->execute(
            $rid,
            $work_resource_id,
            $manif->{biblio_id},
            $props->{publisherName}->[0],
            $props->{publicationPlace}->[0],
            $date,
            $date_sort,
            $props->{manifestationType}->[0],
            $props->{mediaType}->[0],
            $props->{carrierType}->[0],
            $props->{extent}->[0],
        );
        $count++;
    }

    return $count;
}

sub _rebuild_agent_summary {
    my ($self, $only_resource_id) = @_;

    my $dbh = $self->dbh;

    my $where = $only_resource_id
        ? "AND resource_type IN ('Person','Organization','Meeting','Family') AND id = ?"
        : '';

    my $sth = $dbh->prepare(
        "SELECT id, label, label_normalized, resource_type
         FROM record_resources
         WHERE resource_type IN ('Person','Organization','Meeting','Family') $where"
    );

    if ($only_resource_id) {
        $sth->execute($only_resource_id);
    } else {
        $sth->execute();
    }

    my $insert = $dbh->prepare(
        "INSERT INTO record_agent_summary
             (resource_id, agent_type, name, name_normalized, work_count)
         VALUES (?, ?, ?, ?, ?)"
    );

    my $count = 0;
    while (my $agent = $sth->fetchrow_hashref()) {
        my $rid = $agent->{id};

        # Count Works contributed to (creator/contributor links pointing at this agent)
        my $work_count = $self->_count_agent_works($rid);

        $insert->execute(
            $rid,
            $agent->{resource_type},
            $agent->{label} || '',
            $agent->{label_normalized} || $self->_normalize_name($agent->{label} || ''),
            $work_count,
        );
        $count++;
    }

    return $count;
}

# Returns a hashref of property_key -> [value1, value2, ...] for a resource
sub _properties_for {
    my ($self, $resource_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT property_key, value_text
         FROM record_properties
         WHERE resource_id = ?
         ORDER BY sequence, id"
    );
    $sth->execute($resource_id);

    my %props;
    while (my $row = $sth->fetchrow_hashref()) {
        next unless defined $row->{value_text};
        push @{$props{$row->{property_key}}}, $row->{value_text};
    }

    return \%props;
}

# Walks up links from a Manifestation to find its Work resource id
sub _derive_work_resource {
    my ($self, $manif_resource_id) = @_;

    # Manifestation -> Expression (expressionManifested)
    my $sth = $self->dbh->prepare(
        "SELECT target_resource_id
         FROM record_links
         WHERE source_resource_id = ? AND relationship_type = 'expressionManifested'
         LIMIT 1"
    );
    $sth->execute($manif_resource_id);
    my $expr = $sth->fetchrow_arrayref();
    return undef unless $expr;

    # Expression -> Work (expressionOf)
    my $sth2 = $self->dbh->prepare(
        "SELECT target_resource_id
         FROM record_links
         WHERE source_resource_id = ? AND relationship_type = 'expressionOf'
         LIMIT 1"
    );
    $sth2->execute($expr->[0]);
    my $work = $sth2->fetchrow_arrayref();
    return $work ? $work->[0] : undef;
}

# Returns (contributor_count, subject_count, manifestation_count) for a Work
sub _count_linked {
    my ($self, $work_resource_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT relationship_type, COUNT(*) AS c
         FROM record_links
         WHERE source_resource_id = ?
         GROUP BY relationship_type"
    );
    $sth->execute($work_resource_id);

    my (%counts);
    while (my $row = $sth->fetchrow_hashref()) {
        $counts{$row->{relationship_type}} = $row->{c};
    }

    my $contributor = ($counts{creator} || 0) + ($counts{contributor} || 0);
    my $subject = $counts{subject} || 0;
    my $manifestation = $counts{hasExpression} || 0;

    return ($contributor, $subject, $manifestation);
}

# Finds the local original Expression for a Work (language == original_language,
# and not a translation)
sub _find_original_expression {
    my ($self, $work_resource_id, $original_language) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT l.target_resource_id AS rid
         FROM record_links l
         JOIN record_properties lg
              ON lg.resource_id = l.target_resource_id
             AND lg.property_key = 'languageOfExpression'
             AND lg.value_text = ?
         LEFT JOIN record_properties tr
              ON tr.resource_id = l.target_resource_id
             AND tr.property_key = 'isTranslation'
         WHERE l.source_resource_id = ?
           AND l.relationship_type = 'hasExpression'
           AND tr.id IS NULL
         ORDER BY l.id
         LIMIT 1"
    );
    $sth->execute($original_language, $work_resource_id);
    my $row = $sth->fetchrow_arrayref();
    return $row ? ($row->[0]) : ();
}

# Counts Works contributed to by an agent (creator/contributor links pointing at it)
sub _count_agent_works {
    my ($self, $agent_resource_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT COUNT(*) AS c
         FROM record_links
         WHERE target_resource_id = ?
           AND relationship_type IN ('creator','contributor')"
    );
    $sth->execute($agent_resource_id);
    my $row = $sth->fetchrow_arrayref();
    return $row ? $row->[0] : 0;
}

sub _normalize_title {
    my ($self, $title) = @_;

    my $normalized = lc($title // '');
    $normalized =~ s/[.,;:!?]//g;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+|\s+$//g;
    return $normalized;
}

sub _normalize_name {
    my ($self, $name) = @_;

    my $normalized = lc($name // '');
    $normalized =~ s/[.,;:!?]//g;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+|\s+$//g;
    return $normalized;
}

# Parses a publication date string (e.g. "2024", "[2024]", "c2024") into a sortable date
sub _parse_date_for_sort {
    my ($self, $date) = @_;

    return undef unless defined $date;

    my ($year) = $date =~ /(\d{4})/;
    return undef unless $year;

    return "$year-01-01";
}

1;
