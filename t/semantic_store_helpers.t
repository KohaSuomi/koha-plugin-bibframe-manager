#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SemanticStore;

my $store = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SemanticStore->new();

# _role_relationship_type maps MARC relator URIs to BIBFRAME relationship types
is($store->_role_relationship_type('http://id.loc.gov/vocabulary/relators/aut'),
    'creator', 'relator aut -> creator');
is($store->_role_relationship_type('http://id.loc.gov/vocabulary/relators/cre'),
    'creator', 'relator cre -> creator');
is($store->_role_relationship_type('http://id.loc.gov/vocabulary/relators/ctb'),
    'contributor', 'relator ctb -> contributor');
is($store->_role_relationship_type('http://id.loc.gov/vocabulary/relators/edt'),
    undef, 'unmapped relator -> undef');
is($store->_role_relationship_type(undef), undef, 'undef role -> undef');

# _is_rdf_type recognises both the abbreviated and full rdf:type predicate
ok($store->_is_rdf_type('rdf:type'), 'abbreviated rdf:type recognised');
ok($store->_is_rdf_type('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
    'full rdf:type recognised');
ok(!$store->_is_rdf_type('rdfs:label'), 'non rdf:type rejected');

# _marc_key_relationship_type recovers the agent role from the bflc:marcKey
# value, because marc2bibframe2 emits bf:role only as a label.
is($store->_marc_key_relationship_type('1001 $aHaig, Matt,$ekirjoittaja.'),
    'creator', 'MARC 100 main entry -> creator');
is($store->_marc_key_relationship_type('1102 $aKustannusosakeyhtio,'),
    'creator', 'MARC 110 main entry -> creator');
is($store->_marc_key_relationship_type('7001 $aSilvonen, Sarianna,'),
    'contributor', 'MARC 700 added entry -> contributor');
is($store->_marc_key_relationship_type('7102 $aAula & Co,$ekustantaja.'),
    'contributor', 'MARC 710 added entry -> contributor');
is($store->_marc_key_relationship_type('600 $aElamamuutokset,'),
    undef, 'subject field 600 is not a creator/contributor');
is($store->_marc_key_relationship_type('tThe midnight library.'),
    undef, 'marcKey without a numeric tag -> undef');
is($store->_marc_key_relationship_type(undef), undef, 'undef marcKey -> undef');

# _identifiers_from_triples groups standard numbers with their assigner and
# qualifier, so a shared assigner is not de-duplicated away before the pairing
# is read back.
{
    my $triples = [
        { subject => 'inst', predicate => 'rdf:value',   object => '9789523640740', object_type => 'literal' },
        { subject => 'inst', predicate => 'bf:qualifier', object => 'kovakantinen',   object_type => 'literal' },
        { subject => 'inst', predicate => 'rdf:value',   object => '016789639',      object_type => 'literal' },
        { subject => 'inst', predicate => 'bf:assigner', object => 'http://id.loc.gov/vocabulary/organizations/fimelinda', object_type => 'uri' },
        { subject => 'inst', predicate => 'rdf:value',   object => '016789529',      object_type => 'literal' },
        { subject => 'inst', predicate => 'bf:assigner', object => 'http://id.loc.gov/vocabulary/organizations/fimelinda', object_type => 'uri' },
    ];
    my $got = $store->_identifiers_from_triples($triples);
    is(scalar @{ $got->{inst} }, 3, 'three identifiers grouped');

    is($got->{inst}[0]{value}, '9789523640740', 'isbn value captured');
    is($got->{inst}[0]{qualifier}, 'kovakantinen', 'qualifier attached to the isbn');

    is($got->{inst}[1]{value}, '016789639', 'first 035 value captured');
    is($got->{inst}[1]{assigner}, 'http://id.loc.gov/vocabulary/organizations/fimelinda',
        'assigner attached to the first 035');

    is($got->{inst}[2]{value}, '016789529', 'second 035 value captured');
    is($got->{inst}[2]{assigner}, 'http://id.loc.gov/vocabulary/organizations/fimelinda',
        'assigner attached to the second 035 as well');
}

# An unrelated property ends the current identifier, so a later assigner is not
# attributed to a preceding value.
{
    my $triples = [
        { subject => 'inst', predicate => 'rdf:value', object => '016789639', object_type => 'literal' },
        { subject => 'inst', predicate => 'bf:mainTitle', object => 'Keskiyon kirjasto', object_type => 'literal' },
        { subject => 'inst', predicate => 'bf:assigner', object => 'http://example.org/org/x', object_type => 'uri' },
    ];
    my $got = $store->_identifiers_from_triples($triples);
    ok(!exists $got->{inst}[0]{assigner},
        'assigner after an unrelated property is not attributed');
}

# Only literal rdf:value starts an identifier.
{
    my $triples = [
        { subject => 'inst', predicate => 'rdf:value', object => 'http://example.org/x', object_type => 'uri' },
    ];
    is_deeply($store->_identifiers_from_triples($triples), {},
        'uri rdf:value does not start an identifier');
}

# _hub_metadata keeps the bf:Hub original title (MARC 240) and reports the
# agents that only the discarded Hub referenced.
{
    my $triples = [
        { subject => 'work',  predicate => 'rdf:type',   object => 'http://id.loc.gov/ontologies/bibframe/Work',       object_type => 'uri' },
        { subject => 'work',  predicate => 'bf:expressionOf', object => 'hub',                                object_type => 'uri' },
        { subject => 'hub',   predicate => 'rdf:type',   object => 'http://id.loc.gov/ontologies/bibframe/Hub',        object_type => 'uri' },
        { subject => 'hub',   predicate => 'bf:mainTitle', object => 'The midnight library.',                   object_type => 'literal' },
        { subject => 'hub',   predicate => 'bf:agent',   object => 'hubagent',                                   object_type => 'uri' },
        { subject => 'hubagent', predicate => 'rdf:type', object => 'http://id.loc.gov/ontologies/bibframe/Person',   object_type => 'uri' },
        { subject => 'work',  predicate => 'bf:agent',   object => 'workagent',                                   object_type => 'uri' },
    ];
    my $types = {
        work => { type => 'Work' },
        hubagent => { type => 'Person' },
    };
    my $got = $store->_hub_metadata($triples, $types);
    is($got->{original_titles}{work}, 'The midnight library.',
        'hub mainTitle becomes the work original title');
    ok($got->{orphan_agents}{hubagent}, 'agent referenced only by the hub is orphaned');
    ok(!$got->{orphan_agents}{workagent}, 'agent referenced by the work is kept');
}

done_testing;
