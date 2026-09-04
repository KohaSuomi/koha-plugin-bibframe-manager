package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping;

use strict;
use warnings;
use utf8;
use YAML::XS qw(LoadFile);
use File::Spec;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Esmapping

=head1 DESCRIPTION

Loads the Elasticsearch document mapping configuration from
config/es_mapping.yaml.

This config declares how the semantic (BIBFRAME) storage shapes (summary
tables + core tables) map onto the flattened Elasticsearch document,
decoupling the SearchIndex module from hardcoded field/column names.

=cut

our $CONFIG;

sub _load_config {
    return if $CONFIG;

    my $module_dir = __FILE__;
    $module_dir =~ s/Esmapping\.pm$//;
    my $config_file = File::Spec->catfile($module_dir, '..', 'config', 'es_mapping.yaml');

    unless (-f $config_file) {
        die "ES mapping configuration file not found: $config_file";
    }

    $CONFIG = LoadFile($config_file);
}

_load_config();

=head2 get

    my $config = Esmapping::get();

Returns the full ES document mapping config hashref.

=cut

sub get {
    return $CONFIG;
}

=head2 get_section

    my $work_cfg = Esmapping::get_section('work');

Returns a named section of the mapping config, or undef.

=cut

sub get_section {
    my ($name) = @_;
    return unless $name;
    return $CONFIG->{$name};
}

1;
