#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;

my $bf   = 'http://id.loc.gov/ontologies/bibframe/';
my $base = 'http://urn.fi/URN:NBN:fi:bib:';
my $bibframe = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();

sub triples_for {
    my ($work, $instance) = @_;
    return [
        { subject => $work,     predicate => 'rdf:type',   object => "${bf}Work",     object_type => 'uri' },
        { subject => $instance, predicate => 'rdf:type',   object => "${bf}Instance", object_type => 'uri' },
        { subject => $work,     predicate => 'rdfs:label', object => 'Motors',        object_type => 'literal' },
    ];
}

sub subjects { map { $_->{subject} } @{ $_[0] } }

# LoC-style URIs (/resources/works/, /resources/instances/)
{
    my $out = $bibframe->derive_wemi_from_loc(
        triples_for('http://id.loc.gov/resources/works/20962936',
                    'http://id.loc.gov/resources/instances/20962936'),
        base_uri => $base,
    );
    my @subjects = subjects($out);
    ok(scalar(grep { $_ eq "${base}expression/20962936" } @subjects),
        'LoC URIs: expression URI carries the control number');
    is(scalar(grep { m{/(?:expression|item)/$} } @subjects), 0,
        'LoC URIs: no empty-control derived URIs');
    ok(scalar(grep { $_->{predicate} =~ m{hasExpression$} } @$out),
        'LoC URIs: Work -> Expression link emitted');
    ok(scalar(grep { $_->{predicate} =~ m{manifestationOfExpression$} } @$out),
        'LoC URIs: Expression -> Manifestation link emitted');
}

# Record-local URIs with #Work / #Instance fragments (as produced for a
# library-specific base URI, e.g. http://example.org/<biblionumber>/<id>#Work)
{
    my $out = $bibframe->derive_wemi_from_loc(
        triples_for('http://example.org/2/016789639#Work',
                    'http://example.org/2/016789639#Instance'),
        base_uri => $base,
    );
    my @subjects = subjects($out);
    ok(scalar(grep { $_ eq "${base}expression/016789639" } @subjects),
        'fragment URIs: expression URI carries the control number');
    is(scalar(grep { m{/(?:expression|item)/$} } @subjects), 0,
        'fragment URIs: no empty-control derived URIs');
}

# No typed Work/Instance resources -> empty result
{
    my $out = $bibframe->derive_wemi_from_loc(
        [ { subject => 'x', predicate => 'rdfs:label', object => 'y', object_type => 'literal' } ],
        base_uri => $base,
    );
    is_deeply($out, [], 'no Work/Instance types -> empty result');
}

done_testing;
