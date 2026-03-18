package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping;

use strict;
use warnings;
use utf8;
use YAML::XS qw(LoadFile);
use File::Spec;
use FindBin;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping

=head1 DESCRIPTION

Complete Bibframe (Finnish BIBFRAME) mapping configuration based on 
Bibframe 1.0.0 ontology (https://schema.finto.fi/bffi/1-0-0/)

This module loads comprehensive mappings between MARC21 fields and 
Bibframe RDF properties from a YAML configuration file following the 
LKD (Linkitetty kirjastodata) data model.

=head1 CONFIGURATION

All mappings are loaded from config/Bibframe_mapping.yaml

=cut

# Module-level storage for loaded configuration
our $CONFIG;
our $NAMESPACES;
our $CLASSES;
our $MARC21_TO_WORK;
our $MARC21_TO_EXPRESSION;
our $MARC21_TO_MANIFESTATION;
our $MARC21_TO_ITEM;
our $ADMIN_METADATA;
our $CARTOGRAPHIC_FIELDS;
our $RELATIONSHIPS;

# Load configuration on module initialization
sub _load_config {
    return if $CONFIG; # Already loaded
    
    # Find the config file relative to this module
    my $module_dir = __FILE__;
    $module_dir =~ s/Mapping\.pm$//;
    my $config_file = File::Spec->catfile($module_dir, '..', 'config', 'bibframe_mapping.yaml');
    
    unless (-f $config_file) {
        die "Bibframe mapping configuration file not found: $config_file";
    }
    
    $CONFIG = LoadFile($config_file);
    
    # Populate module variables for backward compatibility
    $NAMESPACES = $CONFIG->{namespaces} || {};
    $CLASSES = $CONFIG->{classes} || {};
    $MARC21_TO_WORK = $CONFIG->{marc21_to_work} || {};
    $MARC21_TO_EXPRESSION = $CONFIG->{marc21_to_expression} || {};
    $MARC21_TO_MANIFESTATION = $CONFIG->{marc21_to_manifestation} || {};
    $MARC21_TO_ITEM = $CONFIG->{marc21_to_item} || {};
    $ADMIN_METADATA = $CONFIG->{admin_metadata} || {};
    $CARTOGRAPHIC_FIELDS = $CONFIG->{cartographic_fields} || {};
    $RELATIONSHIPS = $CONFIG->{relationships} || {};
}

# Initialize configuration on module load
_load_config();

=head1 SUBROUTINES

=head2 get_namespace

Returns the full URI for a given prefix

=cut

sub get_namespace {
    my ($prefix) = @_;
    return $NAMESPACES->{$prefix};
}

=head2 get_class_uri

Returns the full URI for a given class name

=cut

sub get_class_uri {
    my ($class_name) = @_;
    return $CLASSES->{$class_name};
}

=head2 get_work_mapping

Returns the Bibframe property mapping for a given MARC21 Work field

=cut

sub get_work_mapping {
    my ($tag) = @_;
    return $MARC21_TO_WORK->{$tag};
}

=head2 get_expression_mapping

Returns the Bibframe property mapping for a given MARC21 Expression field

=cut

sub get_expression_mapping {
    my ($tag) = @_;
    return $MARC21_TO_EXPRESSION->{$tag};
}

=head2 get_manifestation_mapping

Returns the Bibframe property mapping for a given MARC21 Manifestation field

=cut

sub get_manifestation_mapping {
    my ($tag) = @_;
    return $MARC21_TO_MANIFESTATION->{$tag};
}

=head2 get_item_mapping

Returns the Bibframe property mapping for a given MARC21 Item field

=cut

sub get_item_mapping {
    my ($tag) = @_;
    return $MARC21_TO_ITEM->{$tag};
}

=head2 get_admin_mapping

Returns the administrative metadata mapping

=cut

sub get_admin_mapping {
    my ($tag) = @_;
    return $ADMIN_METADATA->{$tag};
}

=head2 get_relationship_uri

Returns the relationship URI

=cut

sub get_relationship_uri {
    my ($rel_name) = @_;
    return $RELATIONSHIPS->{$rel_name};
}

=head1 EXPORT

=cut

our @EXPORT = qw(
    $NAMESPACES
    $CLASSES
    $MARC21_TO_WORK
    $MARC21_TO_EXPRESSION
    $MARC21_TO_MANIFESTATION
    $MARC21_TO_ITEM
    $ADMIN_METADATA
    $CARTOGRAPHIC_FIELDS
    $RELATIONSHIPS
    get_namespace
    get_class_uri
    get_work_mapping
    get_expression_mapping
    get_manifestation_mapping
    get_item_mapping
    get_admin_mapping
    get_relationship_uri
);

1;

__END__

=head1 AUTHOR

Koha-Suomi Oy

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=head1 SEE ALSO

Bibframe Ontology: https://schema.finto.fi/Bibframe/1-0-0/
BIBFRAME 2.4.0: http://id.loc.gov/ontologies/bibframe/
RDA Registry: http://www.rdaregistry.info/

=cut
