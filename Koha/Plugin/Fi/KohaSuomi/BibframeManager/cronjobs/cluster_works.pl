#!/usr/bin/perl

# Copyright 2026 KohaSuomi
#
# Deterministic work clustering (Hybrid Plan Phase 15).
#
# Scans the stored Works in record_resources, applies the Phase 14 decision
# rules, auto-accepts the unambiguous pairs (status='accepted') and routes the
# rest to work_match_candidates (status='pending') for human review. Hard
# blocks never enter the queue.
#
# Usage:
#   perl cluster_works.pl                # run and store decisions
#   perl cluster_works.pl --dry-run      # classify only, do not write
#   perl cluster_works.pl --report       # print current queue counts and exit

use Modern::Perl;
use Getopt::Long qw(GetOptions);
use utf8;
use open ':std', ':encoding(UTF-8)';
use Pod::Usage;
use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::WorkClusterer;

my $dry_run;
my $report;
my $verbose;
my $help;

GetOptions(
    'dry-run' => \$dry_run,
    'report'  => \$report,
    'verbose' => \$verbose,
    'help|?'  => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

my $clusterer = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::WorkClusterer->new();

if ($report) {
    my $dbh = C4::Context->dbh;
    say "=== work_match_candidates by status ===";
    my $sth = $dbh->prepare(
        "SELECT status, COUNT(*) AS c FROM work_match_candidates GROUP BY status"
    );
    $sth->execute();
    while (my $r = $sth->fetchrow_hashref()) {
        say sprintf("  %-10s %d", $r->{status}, $r->{c});
    }
    say "=== by relationship_type (pending) ===";
    my $sth2 = $dbh->prepare(
        "SELECT relationship_type, COUNT(*) AS c FROM work_match_candidates
         WHERE status='pending' GROUP BY relationship_type"
    );
    $sth2->execute();
    while (my $r = $sth2->fetchrow_hashref()) {
        say sprintf("  %-16s %d", $r->{relationship_type}, $r->{c});
    }
    say "=== by match_tier (pending) ===";
    my $sth3 = $dbh->prepare(
        "SELECT match_tier, COUNT(*) AS c FROM work_match_candidates
         WHERE status='pending' GROUP BY match_tier ORDER BY match_tier"
    );
    $sth3->execute();
    while (my $r = $sth3->fetchrow_hashref()) {
        say sprintf("  tier %-3s %d", $r->{match_tier}, $r->{c});
    }
    my ($work_count) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM record_resources WHERE resource_type='Work'"
    );
    say "Stored Works: $work_count";
    exit 0;
}

say "Clustering stored Works" . ($dry_run ? " (dry run)" : "") . "...";
my $stats = $clusterer->cluster_all(dry_run => $dry_run);

say "Works scanned:      $stats->{works}";
say "Pairs examined:     $stats->{pairs_examined}";
say "Auto-merge pairs:   $stats->{auto_merge}";
say "Review candidates:  $stats->{candidate}";
say "Hard blocks:        $stats->{block}";
unless ($dry_run) {
    say "Rows inserted:      $stats->{inserted}";
    say "Rows skipped (existing): $stats->{skipped_existing}";
}
say "By tier:";
for my $tier (sort { $a <=> $b } keys %{ $stats->{by_tier} }) {
    say sprintf("  tier %-3s %d", $tier, $stats->{by_tier}{$tier});
}
say "By relationship:";
for my $rel (sort keys %{ $stats->{by_relationship} }) {
    say sprintf("  %-16s %d", $rel, $stats->{by_relationship}{$rel});
}

=head1 NAME

cluster_works.pl

=head1 DESCRIPTION

Deterministic work clustering runner.

=cut