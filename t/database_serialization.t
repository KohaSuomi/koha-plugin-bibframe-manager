#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use JSON qw(decode_json);
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;

my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new({});

my $bf   = 'http://id.loc.gov/ontologies/bibframe/';
my $work = 'http://example.org/2/016789639#Work';
my $inst = 'http://example.org/2/016789639#Instance';

# A cyclic Work <-> Instance graph. Before the recursion guard this made
# _toJson recurse forever (the deep-recursion freeze).
my $triples = [
    { subject => $work, predicate => 'rdf:type',              object => "${bf}Work",     object_type => 'uri' },
    { subject => $inst, predicate => 'rdf:type',              object => "${bf}Instance", object_type => 'uri' },
    { subject => $work, predicate => "${bf}hasInstance",      object => $inst,           object_type => 'uri' },
    { subject => $inst, predicate => "${bf}instanceOf",       object => $work,           object_type => 'uri' },
    { subject => $work, predicate => 'rdfs:label',            object => 'Motors',        object_type => 'literal' },
];

# JSON: terminates, stays bounded, and breaks the cycle with a URI reference
my $json = $db->serializeTriples($triples, 'json');
ok(defined $json && length $json, 'json serialization returns output');
cmp_ok(length($json), '<', 4000, 'json output is bounded (no runaway nesting)');

my $decoded = eval { decode_json($json) };
ok($decoded, 'json output is valid JSON');
ok($decoded->{work} && $decoded->{manifestation}, 'work and manifestation present');

my $inst_node = $decoded->{work}{instances};
$inst_node = $inst_node->[0] if ref $inst_node eq 'ARRAY';
is($inst_node->{instanceOf}{uri}, $work,
    'back-reference emitted as a URI instead of recursing');

# RDF/XML: the API enum uses 'rdf-xml' while the CLI uses 'rdfxml'
my $xml = $db->serializeTriples($triples, 'rdf-xml');
like($xml, qr{^<\?xml}, 'rdf-xml alias produces XML');
is($db->serializeTriples($triples, 'rdfxml'), $xml,
    'rdfxml and rdf-xml produce identical output');

# Remaining formats stay functional
ok(length $db->serializeTriples($triples, 'turtle'),   'turtle output');
ok(length $db->serializeTriples($triples, 'ntriples'), 'ntriples output');
ok(length $db->serializeTriples($triples, 'json-ld'),  'json-ld output');

is($db->serializeTriples([], 'json'), '{}', 'empty triple set -> {}');

done_testing;
