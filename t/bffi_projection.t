#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;

use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector;

my $BF   = 'http://id.loc.gov/ontologies/bibframe/';
my $BFFI = 'http://urn.fi/URN:NBN:fi:schema:bffi:';
my $base = 'http://urn.fi/URN:NBN:fi:bib:';

sub fixture_triples {
    my $work     = 'http://id.loc.gov/resources/works/20962936';
    my $instance = 'http://id.loc.gov/resources/instances/20962936';
    return {
        work     => $work,
        instance => $instance,
        triples  => [
            { subject => $work, predicate => 'rdf:type', object => $BF . 'Work',  object_type => 'uri' },
            { subject => $work, predicate => 'rdf:type', object => $BF . 'Text',  object_type => 'uri' },
            { subject => $work, predicate => $BF . 'title', object => 'Motors', object_type => 'literal' },
            { subject => $work, predicate => $BF . 'mainTitle', object => 'Motors', object_type => 'literal' },
            { subject => $work, predicate => $BF . 'language', object => 'http://id.loc.gov/vocabulary/languages/eng', object_type => 'uri' },
            { subject => $work, predicate => "${BF}subject", object => 'http://id.loc.gov/authorities/subjects/sh85087538', object_type => 'uri' },
            { subject => $work, predicate => $BF . 'madeUpProperty', object => 'x', object_type => 'literal' },

            { subject => $instance, predicate => 'rdf:type', object => $BF . 'Instance', object_type => 'uri' },
            { subject => $instance, predicate => $BF . 'title', object => 'Motors', object_type => 'literal' },
            { subject => $instance, predicate => $BF . 'identifiedBy', object => '978-0-00-000000-0', object_type => 'literal' },
            { subject => $instance, predicate => $BF . 'extent', object => '256 sivua', object_type => 'literal' },
            { subject => $instance, predicate => $BF . 'hasInstance', object => $BF . 'Instance', object_type => 'uri' },
        ],
    };
}

sub common_assertions {
    my ($out) = @_;
    my @preds = map { $_->{predicate} } @$out;
    my @objs  = map { $_->{object} } @$out;

    ok(!(grep { /^bf:/ || /^bflc:/ } @preds), 'no bf:/bflc: predicates remain');
    ok(!(grep { /\Q$BF\E/ || /\Qhttp:\/\/id.loc.gov\/ontologies\/bflc\E/ } (map { $_->{object_type} && $_->{object_type} eq 'uri' ? $_->{object} : () } @$out)),
        'no LoC class URIs remain in rdf:type');

    ok((grep { $_ eq $BFFI . 'Work' } @objs), 'Work typed as bffi:Work');
    ok((grep { $_ eq $BFFI . 'Expression' } @objs), 'Expression emitted');
    ok((grep { $_ eq $BFFI . 'Manifestation' } @objs), 'Manifestation emitted');

    ok((grep { /bffi:hasExpression$/ } @preds), 'Work -> hasExpression');
    ok((grep { /bffi:expressionOf$/ } @preds), 'Expression -> expressionOf');
    ok((grep { /bffi:manifestationOfExpression$/ } @preds), 'Expression -> manifestationOfExpression');
    ok((grep { /bffi:expressionManifested$/ } @preds), 'Manifestation -> expressionManifested');

    my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new();
    my @bad = $projector->closed_namespace_violations($out);
    is(scalar @bad, 0, 'closed_namespace_violations is empty') or diag explain \@bad;
}

# --- Full projection -------------------------------------------------------
{
    my $f = fixture_triples();
    my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new(base_uri => $base);
    my $out = $projector->project($f->{triples}, base_uri => $base);

    ok(@$out, 'projection returns triples');
    common_assertions($out);

    my @subjects = map { $_->{subject} } @$out;
    ok((grep { $_ eq "${base}expression/20962936" } @subjects), 'expression URI is minted');
    ok((grep { $_ eq "${base}work/20962936" } @subjects), 'work URI is minted');
    ok((grep { $_ eq "${base}manifestation/20962936" } @subjects), 'manifestation URI is minted');
    ok(!(grep { m{id\.loc\.gov/resources} } @subjects), 'no inherited LoC resource URIs as subjects');

    my @expr = grep { $_->{subject} eq "${base}expression/20962936" } @$out;
    ok((grep { $_->{predicate} eq $BFFI . 'language' } @expr), 'language moved to Expression');

    my @work = grep { $_->{subject} eq "${base}work/20962936" } @$out;
    ok(!(grep { $_->{predicate} eq $BFFI . 'language' } @work), 'language no longer on Work');

    my $stats = $projector->stats;
    ok($stats->{dropped} >= 1, 'unmappable predicate counted as dropped');
    ok($stats->{dropped_terms}{'bf:madeUpProperty'}, 'dropped predicate recorded by name');
    ok($stats->{renamed} >= 1, 'renamed predicate counted');
}

# --- Empty input -----------------------------------------------------------
{
    my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new();
    is_deeply($projector->project([]), [], 'empty input -> empty output');
    is_deeply($projector->project(undef), [], 'undef input -> empty output');
}

# --- Instance only (no Work) ----------------------------------------------
{
    my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new(base_uri => $base);
    my $instance = 'http://id.loc.gov/resources/instances/12345';
    my $out = $projector->project([
        { subject => $instance, predicate => 'rdf:type', object => $BF . 'Instance', object_type => 'uri' },
        { subject => $instance, predicate => $BF . 'extent', object => '10 s.', object_type => 'literal' },
    ], base_uri => $base);

    ok(@$out, 'instance-only projection returns triples');
    my @objs = map { $_->{object} } @$out;
    ok((grep { $_ eq $BFFI . 'Manifestation' } @objs), 'instance-only -> bffi:Manifestation');
    ok((grep { $_ eq "${base}manifestation/12345" } (map { $_->{subject} } @$out)), 'instance-only minted URI');
}

# --- Phase 3 routings: axis split, workManifested, aux entities -----------
{
    my $work     = 'http://id.loc.gov/resources/works/42';
    my $instance = 'http://id.loc.gov/resources/instances/42';
    my $lang     = 'http://id.loc.gov/vocabulary/languages/fin';
    my $isbn     = 'http://example.org/id/isbn/978-951-1-29139-8';
    my $rdf      = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';

    my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new(base_uri => $base);
    my $out = $projector->project([
        { subject => $work, predicate => 'rdf:type', object => $BF . 'Work',     object_type => 'uri' },
        { subject => $work, predicate => 'rdf:type', object => $BF . 'Monograph', object_type => 'uri' },
        { subject => $work, predicate => 'rdf:type', object => $BF . 'Text',     object_type => 'uri' },
        { subject => $work, predicate => $BF . 'mainTitle', object => 'Redeemed', object_type => 'literal' },
        { subject => $work, predicate => $BF . 'language', object => $lang, object_type => 'uri' },

        { subject => $instance, predicate => 'rdf:type', object => $BF . 'Instance', object_type => 'uri' },
        { subject => $instance, predicate => $BF . 'identifiedBy', object => $isbn, object_type => 'uri' },

        { subject => $lang, predicate => 'rdf:type', object => $BF . 'Language', object_type => 'uri' },
        { subject => $lang, predicate => 'rdfs:label', object => 'Finnish', object_type => 'literal' },

        { subject => $isbn, predicate => 'rdf:type', object => $BF . 'Isbn', object_type => 'uri' },
        { subject => $isbn, predicate => "${rdf}value", object => '978-951-1-29139-8', object_type => 'literal' },
        { subject => $isbn, predicate => $BF . 'qualifier', object => 'kovakantinen', object_type => 'literal' },
    ], base_uri => $base);

    my @objs = map { $_->{object} } @$out;
    ok((grep { $_ eq $BFFI . 'MonographWork' } @objs), 'axis: Work split -> bffi:MonographWork');
    ok((grep { $_ eq $BFFI . 'MonographExpression' } @objs), 'axis: Expression split -> bffi:MonographExpression');

    my @manif = grep { $_->{subject} eq "${base}manifestation/42" } @$out;
    ok((grep { $_->{predicate} eq $BFFI . 'workManifested' && $_->{object} eq "${base}work/42" } @manif),
        'manifestation -> workManifested -> Work');

    my @isbn_triples = grep { $_->{subject} eq $isbn } @$out;
    ok((grep { $_->{predicate} eq 'rdf:type' && $_->{object} eq $BFFI . 'Identifier' } @isbn_triples),
        'aux: ISBN routed to bffi:Identifier');
    ok((grep { $_->{predicate} eq $BFFI . 'source'
            && $_->{object} eq 'http://id.loc.gov/vocabulary/identifiers/isbn' } @isbn_triples),
        'aux: identifier carries bffi:source scheme URI');
    ok((grep { $_->{predicate} eq $BFFI . 'qualifier' } @isbn_triples) == 1,
        'aux: bf:qualifier routed to bffi:qualifier');
    ok((grep { $_->{predicate} eq 'rdf:value' } @isbn_triples),
        'aux: rdf:value preserved');

    my @lang_triples = grep { $_->{subject} eq $lang } @$out;
    ok((grep { $_->{predicate} eq 'rdf:type' && $_->{object} eq $BFFI . 'Language' } @lang_triples),
        'aux: language typed bffi:Language');
    ok((grep { $_->{predicate} eq 'rdfs:label' } @lang_triples), 'aux: language label preserved');

    my @bad = $projector->closed_namespace_violations($out);
    is(scalar @bad, 0, 'phase 3: closed namespace holds') or diag explain \@bad;
}

# --- Phase 3b fidelity: Contribution reification, aap on all axes, relation -
{
    my $work     = 'http://id.loc.gov/resources/works/77';
    my $instance = 'http://id.loc.gov/resources/instances/77';
    my $agent    = 'http://id.loc.gov/rwo/agents/n81003128';
    my $role     = 'http://id.loc.gov/vocabulary/relators/ctb';
    my $related  = 'http://id.loc.gov/resources/works/8888';

    my $projector = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::BFFIProjector->new(base_uri => $base);
    my $out = $projector->project([
        { subject => $work, predicate => 'rdf:type', object => $BF . 'Work',     object_type => 'uri' },
        { subject => $work, predicate => 'rdf:type', object => $BF . 'Monograph', object_type => 'uri' },
        { subject => $work, predicate => 'bflc:aap', object => 'Motors', object_type => 'literal' },
        { subject => $work, predicate => $BF . 'agent', object => $agent, object_type => 'uri' },
        { subject => $work, predicate => $BF . 'role',  object => $role,  object_type => 'uri' },
        { subject => $work, predicate => $BF . 'relation', object => $related, object_type => 'uri' },

        { subject => $instance, predicate => 'rdf:type', object => $BF . 'Instance', object_type => 'uri' },
    ], base_uri => $base);

    my @work_t   = grep { $_->{subject} eq "${base}work/77" } @$out;
    my @expr_t   = grep { $_->{subject} eq "${base}expression/77" } @$out;
    my @manif_t  = grep { $_->{subject} eq "${base}manifestation/77" } @$out;

    my ($contrib) = map { $_->{object} } grep { $_->{predicate} eq $BFFI . 'contribution' } @work_t;
    ok($contrib, 'contribution: Work links a bffi:Contribution node');

    my @c_t = grep { $_->{subject} eq $contrib } @$out;
    ok((grep { $_->{predicate} eq 'rdf:type' && $_->{object} eq $BFFI . 'Contribution' } @c_t),
        'contribution: node typed bffi:Contribution');
    ok((grep { $_->{predicate} eq $BFFI . 'agent' && $_->{object} eq $agent } @c_t),
        'contribution: node carries bffi:agent');
    ok((grep { $_->{predicate} eq $BFFI . 'role' && $_->{object} eq $role } @c_t),
        'contribution: node carries bffi:role');
    ok((grep { $_->{predicate} eq $BFFI . 'agent' } @work_t) == 0,
        'contribution: no direct bffi:agent left on Work');

    ok((grep { $_->{predicate} eq $BFFI . 'aap' } @work_t),  'aap: present on Work');
    ok((grep { $_->{predicate} eq $BFFI . 'aap' } @expr_t),  'aap: inherited by Expression');
    ok((grep { $_->{predicate} eq $BFFI . 'aap' } @manif_t), 'aap: inherited by Manifestation');

    ok((grep { $_->{predicate} eq $BFFI . 'relation' && $_->{object} eq $related } @work_t),
        'relation: bf:relation forwarded as bffi:relation');
}

done_testing();
