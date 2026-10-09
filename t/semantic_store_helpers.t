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

done_testing;
