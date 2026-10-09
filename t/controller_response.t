#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
require Koha::Plugin::Fi::KohaSuomi::BibframeManager::Controllers::BibframeController;

# Mojolicious::Plugin::OpenAPI validates responses against openapi.yaml; a JSON
# null fails fields typed e.g. "type: integer". Optional fields that cannot be
# filled must be omitted, not returned as undef.
my $out = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Controllers::BibframeController::_defined_response({
    biblio_id    => 2,
    resource_id  => undef,
    storage      => undef,
    work         => undef,
    triple_count => 0,
    stored        => 0,
    message      => 'ok',
});

ok(!exists $out->{resource_id}, 'undef resource_id omitted');
ok(!exists $out->{storage},     'undef storage omitted');
ok(!exists $out->{work},        'undef work omitted');
ok(exists $out->{triple_count} && $out->{triple_count} == 0, 'zero integer kept');
ok(exists $out->{stored} && $out->{stored} == 0,             'false boolean kept');
is($out->{biblio_id}, 2,    'defined integer kept');
is($out->{message}, 'ok',   'defined string kept');

done_testing;
