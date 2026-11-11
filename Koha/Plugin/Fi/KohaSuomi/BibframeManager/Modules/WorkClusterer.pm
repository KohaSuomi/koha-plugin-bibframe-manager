package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::WorkClusterer;

use strict;
use warnings;
use utf8;
use JSON;
use C4::Context;
use MARC::Record;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::WorkClusterer

=head1 DESCRIPTION

Deterministic work-clustering engine (Hybrid Plan Phase 15).

=cut

sub new {
    my ($class, %args) = @_;
    bless { %args }, $class;
}

sub dbh {
    return C4::Context->dbh;
}

sub cluster_all {
    my ($self, %opts) = @_;
    my $dry_run = $opts{dry_run} ? 1 : 0;

    my $works = $self->_load_works();
    my @signals = map { $self->_signals($_) } @$works;

    my %by_id = map { $_->{id} => $_ } @signals;

    my %pair_keys;
    my $add_pair = sub {
        my ($a, $b) = @_;
        return if $a->{id} == $b->{id};
        my ($x, $y) = $a->{id} < $b->{id} ? ($a->{id}, $b->{id}) : ($b->{id}, $a->{id});
        $pair_keys{"$x:$y"} = [$by_id{$x}, $by_id{$y}];
    };

    # Group by normalised title.
    my %by_title;
    for my $w (@signals) {
        next unless $w->{title_normalized};
        push @{ $by_title{ $w->{title_normalized} } }, $w;
    }
    for my $group (values %by_title) {
        next unless @$group > 1;
        for my $i (0 .. $#$group - 1) {
            for my $j ($i + 1 .. $#$group) {
                $add_pair->($group->[$i], $group->[$j]);
            }
        }
    }

    # Group by uniform title.
    my %by_uniform;
    for my $w (@signals) {
        next unless $w->{uniform_title_normalized};
        push @{ $by_uniform{ $w->{uniform_title_normalized} } }, $w;
    }
    for my $group (values %by_uniform) {
        next unless @$group > 1;
        for my $i (0 .. $#$group - 1) {
            for my $j ($i + 1 .. $#$group) {
                $add_pair->($group->[$i], $group->[$j]);
            }
        }
    }

    # Group by creator normalised name.
    my %by_creator;
    for my $w (@signals) {
        for my $c (@{ $w->{creators} }) {
            next unless $c->{normalized};
            push @{ $by_creator{ $c->{normalized} } }, $w;
        }
    }
    for my $group (values %by_creator) {
        my %seen;
        my @uniq = grep { !$seen{ $_->{id} }++ } @$group;
        next unless @uniq > 1;
        for my $i (0 .. $#uniq - 1) {
            for my $j ($i + 1 .. $#uniq) {
                $add_pair->($uniq[$i], $uniq[$j]);
            }
        }
    }

    # Group by shared identifier.
    my %by_identifier;
    for my $w (@signals) {
        for my $id (@{ $w->{identifiers} }) {
            next unless length $id;
            push @{ $by_identifier{$id} }, $w;
        }
    }
    for my $group (values %by_identifier) {
        my %seen;
        my @uniq = grep { !$seen{ $_->{id} }++ } @$group;
        next unless @uniq > 1;
        for my $i (0 .. $#uniq - 1) {
            for my $j ($i + 1 .. $#uniq) {
                $add_pair->($uniq[$i], $uniq[$j]);
            }
        }
    }

    my $stats = {
        works            => scalar(@signals),
        pairs_examined   => 0,
        auto_merge       => 0,
        candidate        => 0,
        block            => 0,
        inserted         => 0,
        skipped_existing => 0,
        by_tier          => {},
        by_relationship  => {},
    };

    for my $pair (values %pair_keys) {
        my ($a, $b) = @$pair;
        $stats->{pairs_examined}++;

        my $decision = $self->_decide($a, $b);
        next unless $decision;

        my $tier = $decision->{tier};
        my $rel  = $decision->{relationship_type};
        $stats->{by_tier}{$tier}++;
        $stats->{by_relationship}{$rel}++;

        if ($decision->{action} eq 'block') {
            $stats->{block}++;
            next;
        }

        if ($decision->{action} eq 'auto_merge') {
            $stats->{auto_merge}++;
            next if $dry_run;
            my $ins = $self->_insert_candidate($a, $b, $decision, 'accepted',
                "auto-accepted by rule $tier");
            $stats->{inserted}++        if $ins == 1;
            $stats->{skipped_existing}++ if $ins == 0;
        }
        elsif ($decision->{action} eq 'candidate') {
            $stats->{candidate}++;
            next if $dry_run;
            my $ins = $self->_insert_candidate($a, $b, $decision, 'pending', undef);
            $stats->{inserted}++        if $ins == 1;
            $stats->{skipped_existing}++ if $ins == 0;
        }
    }

    return $stats;
}

sub _decide {
    my ($self, $a, $b) = @_;

    my $evidence = $self->_evidence($a, $b);

    # hard blocks
    if ($self->_is_adaptation($a, $b, $evidence)) {
        return { action => 'block', tier => 9, relationship_type => 'adaptation',
                 evidence => $evidence };
    }

    if (defined $a->{work_type} && defined $b->{work_type}
        && $a->{work_type} ne $b->{work_type}) {
        return { action => 'block', tier => 10, relationship_type => 'adaptation',
                 evidence => $evidence };
    }

    if ($self->_is_free_translation_explicit($a, $b, $evidence)) {
        return { action => 'block', tier => 13, relationship_type => 'freetranslation',
                 evidence => $evidence };
    }

    my $creator_match  = $self->_creators_intersect($a, $b);
    my $creator_corrob = $self->_creator_corroborated($a, $b, $evidence);
    my $work_type_ok   = $self->_work_type_compatible($a, $b);
    my $date_ok        = $self->_date_compatible($a, $b);
    my $shared_id      = $self->_shared_identifier($a, $b);
    my $uniform_match  = $self->_uniform_title_match($a, $b);
    my $title_identical = $self->_title_identical($a, $b);
    my $title_near     = $self->_title_near($a, $b);
    my $same_language  = (defined $a->{language} && defined $b->{language}
                          && $a->{language} eq $b->{language});
    my $cross_language = (defined $a->{language} && defined $b->{language}
                          && $a->{language} ne $b->{language});

    # auto-merge rules
    if ($shared_id && $creator_match && $work_type_ok && $date_ok) {
        return { action => 'auto_merge', tier => 1,
                 relationship_type => ($cross_language ? 'translation' : 'edition'),
                 evidence => $evidence };
    }

    if ($uniform_match && $creator_match && $work_type_ok) {
        return { action => 'auto_merge', tier => 2,
                 relationship_type => ($cross_language ? 'translation' : 'edition'),
                 evidence => $evidence };
    }

    if ($title_identical && $same_language && $creator_match && $work_type_ok && $date_ok) {
        return { action => 'auto_merge', tier => 3,
                 relationship_type => 'edition', evidence => $evidence };
    }

    if ($title_near && $same_language && $creator_match && $work_type_ok && $date_ok) {
        return { action => 'auto_merge', tier => 4,
                 relationship_type => 'edition', evidence => $evidence };
    }

    if ($a->{is_translation} && defined $a->{original_language}
        && defined $b->{language} && $a->{original_language} eq $b->{language}
        && $creator_match && $work_type_ok) {
        return { action => 'auto_merge', tier => 6,
                 relationship_type => 'translation', evidence => $evidence };
    }
    if ($b->{is_translation} && defined $b->{original_language}
        && defined $a->{language} && $b->{original_language} eq $a->{language}
        && $creator_match && $work_type_ok) {
        return { action => 'auto_merge', tier => 6,
                 relationship_type => 'translation', evidence => $evidence };
    }

    # review candidates
    if ($cross_language && !$uniform_match && !$shared_id
        && ($creator_match || $title_identical || $title_near)) {
        return { action => 'candidate', tier => 7, relationship_type => 'translation',
                 evidence => $evidence };
    }

    if ($cross_language && ($a->{is_translation} || $b->{is_translation})
        && !$title_identical && !$title_near && !$uniform_match) {
        return { action => 'candidate', tier => 13, relationship_type => 'freetranslation',
                 evidence => $evidence };
    }

    if (($title_identical || $title_near || $uniform_match) && $creator_match
        && !$date_ok) {
        return { action => 'candidate', tier => 11, relationship_type => 'edition',
                 evidence => $evidence };
    }

    if ($creator_match && !$creator_corrob
        && ($title_identical || $title_near || $uniform_match)) {
        return { action => 'candidate', tier => 12, relationship_type => 'unknown',
                 evidence => $evidence };
    }

    my $a_has_creators = scalar(@{ $a->{creators} }) > 0;
    my $b_has_creators = scalar(@{ $b->{creators} }) > 0;
    if ((!$a_has_creators || !$b_has_creators)
        && ($title_identical || $title_near || $uniform_match)) {
        return { action => 'candidate', tier => 8, relationship_type => 'unknown',
                 evidence => $evidence };
    }

    if ($creator_match && $self->_title_contains($a, $b)) {
        return { action => 'candidate', tier => 8, relationship_type => 'unknown',
                 evidence => $evidence };
    }

    return undef;
}

sub _insert_candidate {
    my ($self, $a, $b, $decision, $status, $note) = @_;

    my $dbh = $self->dbh;
    my $evidence_json = eval { JSON->new->canonical->encode($decision->{evidence}) } || '{}';

    my $sql;
    if ($status eq 'accepted') {
        $sql = "INSERT INTO work_match_candidates
            (resource_a_id, resource_b_id, match_tier, relationship_type,
             work_type_a, work_type_b, match_evidence, status, review_note,
             reviewed_by, reviewed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,NOW())";
    }
    else {
        $sql = "INSERT INTO work_match_candidates
            (resource_a_id, resource_b_id, match_tier, relationship_type,
             work_type_a, work_type_b, match_evidence, status, review_note,
             reviewed_by, reviewed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)";
    }

    my $sth = $dbh->prepare($sql);
    eval {
        if ($status eq 'accepted') {
            $sth->execute(
                $a->{id}, $b->{id}, $decision->{tier}, $decision->{relationship_type},
                $a->{work_type}, $b->{work_type}, $evidence_json, $status, $note,
                'WorkClusterer (auto)',
            );
        }
        else {
            $sth->execute(
                $a->{id}, $b->{id}, $decision->{tier}, $decision->{relationship_type},
                $a->{work_type}, $b->{work_type}, $evidence_json, $status, $note,
                undef, undef,
            );
        }
    };
    if ($@) {
        if ($@ =~ /Duplicate/i) {
            return 0;
        }
        warn "WorkClusterer insert failed: $@\n";
        return -1;
    }
    return 1;
}

sub _load_works {
    my ($self) = @_;
    my $dbh = $self->dbh;

    my $sth = $dbh->prepare(
        "SELECT id, uri, biblio_id, label, label_normalized
         FROM record_resources
         WHERE resource_type = 'Work'
         ORDER BY id"
    );
    $sth->execute();

    my @works;
    while (my $row = $sth->fetchrow_hashref()) {
        push @works, $row;
    }
    return \@works;
}

sub _signals {
    my ($self, $work) = @_;
    my $dbh = $self->dbh;
    my $wid = $work->{id};

    my $props = {};
    my $psth = $dbh->prepare(
        "SELECT property_key, value_text FROM record_properties WHERE resource_id = ?"
    );
    $psth->execute($wid);
    while (my $r = $psth->fetchrow_hashref()) {
        push @{ $props->{ $r->{property_key} } }, $r->{value_text};
    }

    my $title = $props->{title}[0] || $props->{mainTitle}[0] || $work->{label} || '';
    my $title_normalized = $self->_normalize_title($title);

    my $uniform_title = $props->{uniformTitle}[0];
    my $uniform_title_normalized = $uniform_title ? $self->_normalize_title($uniform_title) : undef;

    my $language = $props->{language}[0] || $props->{languageOfExpression}[0];
    my $original_language = $props->{originalLanguage}[0] || $props->{original_language}[0];
    my $is_translation = ($props->{isTranslation}[0] // '') eq 'true' ? 1 : 0;

    my @creators;
    my $csth = $dbh->prepare(
        "SELECT l.target_resource_id AS agent_id, l.relationship_type, r.label, r.label_normalized
         FROM record_links l JOIN record_resources r ON r.id = l.target_resource_id
         WHERE l.source_resource_id = ? AND l.relationship_type IN ('creator','contributor','agent')
         UNION
         SELECT l.source_resource_id AS agent_id, l.relationship_type, r.label, r.label_normalized
         FROM record_links l JOIN record_resources r ON r.id = l.source_resource_id
         WHERE l.target_resource_id = ? AND l.relationship_type IN ('creator','contributor','agent')"
    );
    $csth->execute($wid, $wid);
    my %seen_agents;
    while (my $r = $csth->fetchrow_hashref()) {
        next if $seen_agents{ $r->{agent_id} }++;
        my $date;
        my $dsth = $dbh->prepare(
            "SELECT value_text FROM record_properties WHERE resource_id = ? AND property_key = 'date' LIMIT 1"
        );
        $dsth->execute($r->{agent_id});
        my $drow = $dsth->fetchrow_hashref();
        $date = $drow->{value_text} if $drow;

        my $norm = $r->{label_normalized} || $self->_normalize_name($r->{label} || '');
        push @creators, {
            agent_id   => $r->{agent_id},
            name       => $r->{label} || '',
            normalized => $norm,
            date       => $date,
            role       => $r->{relationship_type},
        };
    }

    my @identifiers;
    if ($props->{identifier}) {
        push @identifiers, @{ $props->{identifier} };
    }
    if ($props->{identifiers}) {
        for my $raw (@{ $props->{identifiers} }) {
            my $parsed = eval { JSON->new->decode($raw) };
            if (ref $parsed eq 'ARRAY') {
                for my $e (@$parsed) {
                    push @identifiers, $e->{value} if ref $e eq 'HASH' && defined $e->{value};
                }
            }
            else {
                push @identifiers, $raw;
            }
        }
    }
    my %id_seen;
    @identifiers = grep { !$id_seen{$_}++ } @identifiers;

    my $publication_date;
    my $isth = $dbh->prepare(
        "SELECT l.target_resource_id AS instance_id
         FROM record_links l
         WHERE l.source_resource_id = ? AND l.relationship_type IN ('hasInstance','hasExpression')
         UNION
         SELECT l.source_resource_id AS instance_id
         FROM record_links l
         WHERE l.target_resource_id = ? AND l.relationship_type IN ('instanceOf','expressionOf')
         LIMIT 1"
    );
    $isth->execute($wid, $wid);
    my $irow = $isth->fetchrow_hashref();
    if ($irow && $irow->{instance_id}) {
        my $ssth = $dbh->prepare(
            "SELECT publication_date FROM record_instance_summary WHERE resource_id = ? LIMIT 1"
        );
        $ssth->execute($irow->{instance_id});
        my $srow = $ssth->fetchrow_hashref();
        $publication_date = $srow->{publication_date} if $srow;
        if (!$publication_date) {
            my $pp = $dbh->prepare(
                "SELECT value_text FROM record_properties WHERE resource_id = ? AND property_key = 'publicationDate' LIMIT 1"
            );
            $pp->execute($irow->{instance_id});
            my $prow = $pp->fetchrow_hashref();
            $publication_date = $prow->{value_text} if $prow;
        }
    }

    my $work_type = $self->_derive_work_type($wid);

    return {
        id                     => $wid,
        uri                    => $work->{uri},
        biblio_id              => $work->{biblio_id},
        label                  => $work->{label},
        title                  => $title,
        title_normalized       => $title_normalized,
        uniform_title          => $uniform_title,
        uniform_title_normalized => $uniform_title_normalized,
        language               => $language,
        original_language      => $original_language,
        is_translation         => $is_translation,
        original_title         => $props->{originalTitle}[0],
        work_type              => $work_type,
        creators               => \@creators,
        identifiers            => \@identifiers,
        publication_date       => $publication_date,
        props                  => $props,
    };
}

sub _derive_work_type {
    my ($self, $work_id) = @_;
    my $dbh = $self->dbh;

    my $isth = $dbh->prepare(
        "SELECT target_resource_id AS iid FROM record_links
         WHERE source_resource_id = ? AND relationship_type IN ('hasInstance','hasExpression')
         UNION
         SELECT source_resource_id AS iid FROM record_links
         WHERE target_resource_id = ? AND relationship_type IN ('instanceOf','expressionOf')
         LIMIT 1"
    );
    $isth->execute($work_id, $work_id);
    my $irow = $isth->fetchrow_hashref();
    return undef unless $irow && $irow->{iid};

    my $msth = $dbh->prepare(
        "SELECT serialized_data FROM record_format_mappings
         WHERE resource_id = ? AND format_name = 'marc21' LIMIT 1"
    );
    $msth->execute($irow->{iid});
    my $mrow = $msth->fetchrow_hashref();
    return undef unless $mrow && $mrow->{serialized_data};

    my $record;
    eval { $record = MARC::Record->new_from_xml($mrow->{serialized_data}); };
    return undef if $@ || !$record;

    my $leader = $record->leader() || '';
    return undef if length($leader) < 8;
    my $bib_level = substr($leader, 7, 1);
    if ($bib_level =~ /^[sib]$/) {
        return 'serial';
    }
    if ($bib_level =~ /^[macd]$/) {
        return 'monograph';
    }
    return undef;
}

sub _normalize_title {
    my ($self, $title) = @_;
    my $n = lc($title // '');
    $n =~ s/[.,;:!?()\[\]"']//g;
    $n =~ s/\s+/ /g;
    $n =~ s/^\s+|\s+$//g;
    return $n;
}

sub _normalize_name {
    my ($self, $name) = @_;
    my $n = lc($name // '');
    $n =~ s/[.,;:!?]//g;
    $n =~ s/\s+/ /g;
    $n =~ s/^\s+|\s+$//g;
    if ($n =~ /^(\w+),\s+(.+)$/) {
        $n = "$2 $1";
    }
    return $n;
}

sub _creators_intersect {
    my ($self, $a, $b) = @_;
    my %names = map { $_->{normalized} => 1 } @{ $a->{creators} };
    for my $c (@{ $b->{creators} }) {
        return 1 if $names{ $c->{normalized} };
    }
    return 0;
}

sub _creator_corroborated {
    my ($self, $a, $b) = @_;
    my %dates_a = map { $_->{date} => 1 } grep { $_->{date} } @{ $a->{creators} };
    for my $c (@{ $b->{creators} }) {
        return 1 if $c->{date} && $dates_a{ $c->{date} };
    }
    if (defined $a->{uniform_title_normalized} && defined $b->{uniform_title_normalized}
        && $a->{uniform_title_normalized} eq $b->{uniform_title_normalized}) {
        return 1;
    }
    if ($self->_shared_identifier($a, $b)) {
        return 1;
    }
    if ($self->_title_identical($a, $b)) {
        return 1;
    }
    return 0;
}

sub _work_type_compatible {
    my ($self, $a, $b) = @_;
    return 1 unless (defined $a->{work_type} && defined $b->{work_type});
    return $a->{work_type} eq $b->{work_type};
}

sub _date_compatible {
    my ($self, $a, $b) = @_;
    my $ya = $self->_year_from_date($a->{publication_date});
    my $yb = $self->_year_from_date($b->{publication_date});
    return 1 unless (defined $ya && defined $yb);
    return (abs($ya - $yb) <= 20);
}

sub _year_from_date {
    my ($self, $d) = @_;
    return undef unless defined $d;
    if ($d =~ /(\d{4})/) {
        return $1 + 0;
    }
    return undef;
}

sub _shared_identifier {
    my ($self, $a, $b) = @_;
    my %ids = map { $_ => 1 } @{ $a->{identifiers} };
    for my $id (@{ $b->{identifiers} }) {
        return $id if $ids{$id};
    }
    return undef;
}

sub _uniform_title_match {
    my ($self, $a, $b) = @_;
    return 0 unless (defined $a->{uniform_title_normalized} && defined $b->{uniform_title_normalized});
    return $a->{uniform_title_normalized} eq $b->{uniform_title_normalized};
}

sub _title_identical {
    my ($self, $a, $b) = @_;
    return 0 unless (length $a->{title_normalized} && length $b->{title_normalized});
    return $a->{title_normalized} eq $b->{title_normalized};
}

sub _title_near {
    my ($self, $a, $b) = @_;
    return 0 unless (length $a->{title_normalized} && length $b->{title_normalized});
    my $d = $self->_levenshtein($a->{title_normalized}, $b->{title_normalized});
    my $maxlen = length($a->{title_normalized}) > length($b->{title_normalized})
        ? length($a->{title_normalized}) : length($b->{title_normalized});
    return 0 if $maxlen == 0;
    return ($d <= 3 || ($d / $maxlen) <= 0.15);
}

sub _title_contains {
    my ($self, $a, $b) = @_;
    my $ta = $a->{title_normalized};
    my $tb = $b->{title_normalized};
    return 0 unless (length $ta && length $tb);
    return 1 if index($ta, $tb) >= 0 || index($tb, $ta) >= 0;
    return 0;
}

sub _is_adaptation {
    my ($self, $a, $b, $evidence) = @_;
    for my $w ($a, $b) {
        for my $vals (values %{ $w->{props} }) {
            for my $v (@$vals) {
                return 1 if defined $v && $v =~ /adapt/i;
            }
        }
    }
    return 0;
}

sub _is_free_translation_explicit {
    my ($self, $a, $b, $evidence) = @_;
    my @markers = qw(freely[\s-]?translated retold paraphrased rendered[\s-]?as);
    for my $w ($a, $b) {
        for my $vals (values %{ $w->{props} }) {
            for my $v (@$vals) {
                next unless defined $v;
                for my $m (@markers) {
                    return 1 if $v =~ /$m/i;
                }
            }
        }
    }
    return 0;
}

sub _evidence {
    my ($self, $a, $b) = @_;
    return {
        title_a            => $a->{title},
        title_b            => $b->{title},
        title_normalized_a => $a->{title_normalized},
        title_normalized_b => $b->{title_normalized},
        uniform_title_a    => $a->{uniform_title},
        uniform_title_b    => $b->{uniform_title},
        language_a         => $a->{language},
        language_b         => $b->{language},
        original_language_a => $a->{original_language},
        original_language_b => $b->{original_language},
        is_translation_a   => $a->{is_translation},
        is_translation_b   => $b->{is_translation},
        work_type_a        => $a->{work_type},
        work_type_b        => $b->{work_type},
        creators_a         => [ map { $_->{name} } @{ $a->{creators} } ],
        creators_b         => [ map { $_->{name} } @{ $b->{creators} } ],
        shared_identifier  => $self->_shared_identifier($a, $b),
        publication_date_a => $a->{publication_date},
        publication_date_b => $b->{publication_date},
    };
}

sub _levenshtein {
    my ($self, $s, $t) = @_;
    return 0 if $s eq $t;
    my $ls = length($s);
    my $lt = length($t);
    return $lt if $ls == 0;
    return $ls if $lt == 0;

    my @prev = (0 .. $lt);
    for (my $i = 1; $i <= $ls; $i++) {
        my @cur = ($i);
        my $sc = substr($s, $i - 1, 1);
        for (my $j = 1; $j <= $lt; $j++) {
            my $cost = (substr($t, $j - 1, 1) eq $sc) ? 0 : 1;
            my $del = $prev[$j] + 1;
            my $ins = $cur[$j - 1] + 1;
            my $sub = $prev[$j - 1] + $cost;
            my $m = $del < $ins ? $del : $ins;
            $m = $sub if $sub < $m;
            push @cur, $m;
        }
        @prev = @cur;
    }
    return $prev[$lt];
}

1;