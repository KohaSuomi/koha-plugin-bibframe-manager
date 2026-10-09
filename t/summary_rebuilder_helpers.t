#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryRebuilder;

my $rebuilder = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryRebuilder->new();

# _first_value walks the property keys in priority order, so a record converted
# by either engine (BFFI publisherName vs LoC simpleAgent) resolves.
my $props = {
    publisherName => [],
    simpleAgent   => ['Aula & Co', 'Tallinna Raamatutrukikoja OU'],
};
is($rebuilder->_first_value($props, 'publisherName', 'simpleAgent'),
    'Aula & Co', 'first_value skips empty keys and takes the first value');
is($rebuilder->_first_value($props, 'publicationDate'), undef,
    'first_value returns undef when no key is present');

# _vocabulary_term reduces a controlled-vocabulary URI to its term
is($rebuilder->_vocabulary_term('http://id.loc.gov/vocabulary/mediaTypes/n'),
    'n', 'vocabulary_term takes the last URI segment');
is($rebuilder->_vocabulary_term('kovakantinen'), 'kovakantinen',
    'vocabulary_term leaves a plain value alone');
is($rebuilder->_vocabulary_term(undef), undef, 'vocabulary_term handles undef');

# _identifier_type classifies standard numbers
is($rebuilder->_identifier_type('9789523640740'), 'isbn', 'ISBN-13 detected');
is($rebuilder->_identifier_type('9512345678'), 'isbn', 'ISBN-10 detected');
is($rebuilder->_identifier_type('1234-5678'), 'issn', 'ISSN detected');
is($rebuilder->_identifier_type('016789639'), 'identifier',
    'control number left as a generic identifier');

# _extent_for prefers an explicit extent, then a label that looks like one
is($rebuilder->_extent_for({ extent => ['2 volumes'] }), '2 volumes',
    'extent_for prefers the explicit extent property');
is($rebuilder->_extent_for({ label => ['Kansikuva', '328 sivua'] }), '328 sivua',
    'extent_for picks the label that looks like an extent');
is($rebuilder->_extent_for({ label => ['Kansikuva'] }), undef,
    'extent_for ignores non-extent labels');
is($rebuilder->_extent_for({}), undef, 'extent_for handles empty properties');

done_testing;