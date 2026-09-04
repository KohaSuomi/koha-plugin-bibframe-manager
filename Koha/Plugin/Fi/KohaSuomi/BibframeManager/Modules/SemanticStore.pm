package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SemanticStore;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use JSON;
use Digest::MD5 qw(md5_hex);
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryRebuilder;
use C4::Context;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SemanticStore

=head1 DESCRIPTION

Converts MARC21/BIBFRAME records to semantic primitives stored in the hybrid
storage layer (record_resources, record_properties, record_links).

This is the canonical source of truth for all bibliographic data.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        base_uri => $args{base_uri} || 'http://urn.fi/URN:NBN:fi:bib:',
        %args,
    };
    bless($self, $class);
    return $self;
}

sub dbh {
    return C4::Context->dbh;
}

=head1 PUBLIC METHODS

=head2 store_marc_record

    my $result = $store->store_marc_record($marc_record, %options);

Stores a MARC21 record as semantic primitives using the LoC BIBFRAME 3-level
model (Work -> Instance -> Item) as the canonical stored form. The 4-level WEMI
(with Expression) is derived on BFFI export.

Parameters:
    $marc_record - MARC::Record object
    %options:
        biblio_id    - Koha biblionumber (optional)
        source_format - 'marc21' (default), 'imported'

Returns:
    Hashref with resource_ids and counts

=cut

sub store_marc_record {
    my ($self, $marc_record, %options) = @_;

    my $biblio_id = $options{biblio_id};
    my $source_format = $options{source_format} || 'marc21';

    my $control_number = $marc_record->field('001')
        ? $marc_record->field('001')->data()
        : 'unknown';

    my $base_uri = $self->{base_uri};

    # Generate URIs for LoC 3-level entities (no Item URI from MARC - items come from Koha's items table)
    my $work_uri = "${base_uri}work/${control_number}";
    my $instance_uri = "${base_uri}instance/${control_number}";

    my @resources_to_insert;
    my %properties_to_insert;
    my @links_to_insert;

    # 1. Create LoC 3-level resources (Work, Instance only)
    push @resources_to_insert, {
        uri => $work_uri,
        resource_type => 'Work',
        biblio_id => $biblio_id,
        label => $self->_extract_work_label($marc_record),
        source_format => $source_format,
    };

    push @resources_to_insert, {
        uri => $instance_uri,
        resource_type => 'Instance',
        biblio_id => $biblio_id,
        label => $self->_extract_instance_label($marc_record),
        source_format => $source_format,
    };

    # Items are created separately via store_items_from_koha() - they link to Koha's items table

    # 2. Create Work -> Instance links (LoC relationships)
    my $bffi_ns = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');

    push @links_to_insert, {
        source_uri => $work_uri,
        target_uri => $instance_uri,
        relationship_type => 'hasInstance',
        relationship_uri => "${bffi_ns}hasInstance",
    };

    push @links_to_insert, {
        source_uri => $instance_uri,
        target_uri => $work_uri,
        relationship_type => 'instanceOf',
        relationship_uri => "${bffi_ns}instanceOf",
    };

    # 3. Extract and store Work-level properties (incl. language/translation in LoC's Work)
    $self->_extract_work_properties($marc_record, $work_uri, \%properties_to_insert);

    # 4. Extract and store Instance-level properties
    $self->_extract_instance_properties($marc_record, $instance_uri, \%properties_to_insert);

    # Note: Item properties come from Koha's items table, not from MARC 8XX fields

    # 5. Extract and store Agents (deduplicated), linked to the Work
    $self->_extract_agents($marc_record, $work_uri, $base_uri,
        \@resources_to_insert, \%properties_to_insert, \@links_to_insert);

    # 6. Extract and store Subjects (deduplicated), linked to the Work
    $self->_extract_subjects($marc_record, $work_uri, $base_uri,
        \@resources_to_insert, \%properties_to_insert, \@links_to_insert);

    # 7. Execute inserts in transaction
    my $result = $self->_execute_storage(
        \@resources_to_insert,
        \%properties_to_insert,
        \@links_to_insert,
        $control_number
    );

    $result->{control_number} = $control_number;
    $result->{work_uri} = $work_uri;
    $result->{instance_uri} = $instance_uri;

    # Rebuild summary table rows for the entities just stored
    $self->_rebuild_summaries({
        $work_uri          => 'Work',
        $instance_uri      => 'Instance',
    });

    return $result;
}

=head2 store_bibframe_rdf

    my $result = $store->store_bibframe_rdf($triples, %options);

Stores BIBFRAME RDF triples as semantic primitives.

Parameters:
    $triples - Arrayref of RDF triple hashrefs
    %options:
        biblio_id    - Koha biblionumber (optional)
        source_format - 'bibframe' (default), 'bffi'

Returns:
    Hashref with resource_ids and counts

=cut

sub store_bibframe_rdf {
    my ($self, $triples, %options) = @_;

    my $biblio_id = $options{biblio_id};
    my $source_format = $options{source_format} || 'bibframe';

    my %resources_to_insert;
    my @properties_to_insert;
    my @links_to_insert;

    # BIBFRAME type URIs
    # The LoC 3-level model (Work -> Instance -> Item) is the canonical stored
    # form, so LoC Instance maps to the stored 'Instance' type. BFFI 4-level
    # input still maps Manifestation to Manifestation.
    my %type_map = (
        'http://id.loc.gov/ontologies/bibframe/Work'         => 'Work',
        'http://id.loc.gov/ontologies/bibframe/Expression'   => 'Expression',
        'http://id.loc.gov/ontologies/bibframe/Instance'     => 'Instance',
        'http://id.loc.gov/ontologies/bibframe/Item'         => 'Item',
        'http://id.loc.gov/ontologies/bibframe/Agent'        => 'Agent',
        'http://id.loc.gov/ontologies/bibframe/Person'       => 'Person',
        'http://id.loc.gov/ontologies/bibframe/Organization' => 'Organization',
        'http://id.loc.gov/ontologies/bibframe/Meeting'      => 'Meeting',
        'http://id.loc.gov/ontologies/bibframe/Topic'        => 'Topic',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Work'          => 'Work',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Expression'    => 'Expression',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Manifestation' => 'Manifestation',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Item'          => 'Item',
    );

    # Relationship URIs for link extraction
    my %relationship_map = (
        'hasExpression' => 'hasExpression',
        'expressionOf' => 'expressionOf',
        'manifestationOfExpression' => 'manifestationOfExpression',
        'expressionManifested' => 'expressionManifested',
        'hasInstance' => 'hasInstance',
        'instanceOf' => 'instanceOf',
        'hasItem' => 'hasItem',
        'itemOf' => 'itemOf',
        'contribution' => 'contribution',
        'subject' => 'subject',
        'partOf' => 'partOf',
        'hasPart' => 'hasPart',
    );

    # First pass: identify resources and their types
    for my $triple (@$triples) {
        my $subject = $triple->{subject};
        my $predicate = $triple->{predicate};
        my $object = $triple->{object};
        my $object_type = $triple->{object_type};

        # Detect rdf:type
        if ($predicate =~ /rdf:type$/ && $object_type eq 'uri') {
            my $resource_type = $type_map{$object};
            if ($resource_type && !$resources_to_insert{$subject}) {
                $resources_to_insert{$subject} = {
                    uri => $subject,
                    resource_type => $resource_type,
                    biblio_id => $biblio_id,
                    source_format => $source_format,
                };
            }
        }
    }

    # Second pass: extract properties and links
    for my $triple (@$triples) {
        my $subject = $triple->{subject};
        my $predicate = $triple->{predicate};
        my $object = $triple->{object};
        my $object_type = $triple->{object_type};

        # Skip rdf:type (already handled)
        next if $predicate =~ /rdf:type$/;

        # Extract predicate local name
        my ($localname) = $predicate =~ m{[/#]([^/#]+)$};
        next unless $localname;

        # Check if this is a relationship (object is URI to another resource)
        if ($object_type eq 'uri' && exists $resources_to_insert{$object}) {
            # This is a link between resources
            my $rel_type = $relationship_map{$localname} || $localname;
            push @links_to_insert, {
                source_uri => $subject,
                target_uri => $object,
                relationship_type => $rel_type,
                relationship_uri => $predicate,
            };
            next;
        }

        # Otherwise, it's a property
        my $value_type = ($object_type eq 'uri') ? 'resource' : 'literal';
        my $value_text = ($value_type eq 'literal') ? $object : undef;
        my $value_resource_uri = ($value_type eq 'resource') ? $object : undef;

        push @properties_to_insert, {
            resource_uri => $subject,
            property_uri => $predicate,
            property_key => $localname,
            value_type => $value_type,
            value_text => $value_text,
            value_resource_uri => $value_resource_uri,
            value_lang => $triple->{lang},
            value_datatype => $triple->{datatype},
        };
    }

    # Execute storage
    my $result = $self->_execute_storage(
        [values %resources_to_insert],
        \@properties_to_insert,
        \@links_to_insert
    );

    # Rebuild summary table rows for the entities just stored
    $self->_rebuild_summaries(\%resources_to_insert);

    return $result;
}

=head1 PRIVATE METHODS

=cut

sub _extract_work_label {
    my ($self, $marc_record) = @_;

    # Use 245 $a as primary label
    if (my $field_245 = $marc_record->field('245')) {
        return $field_245->subfield('a') || '';
    }
    return '';
}

sub _extract_expression_label {
    my ($self, $marc_record) = @_;

    # Expression label includes edition info
    my $label = $self->_extract_work_label($marc_record);
    if (my $field_250 = $marc_record->field('250')) {
        $label .= ' ' . ($field_250->subfield('a') || '');
    }
    return $label;
}

sub _extract_instance_label {
    my ($self, $marc_record) = @_;

    # Instance label includes publication info
    my $label = $self->_extract_work_label($marc_record);
    if (my $field_264 = $marc_record->field('264')) {
        my $place = $field_264->subfield('a') || '';
        my $name = $field_264->subfield('b') || '';
        my $date = $field_264->subfield('c') || '';
        $label .= " ($place : $name, $date)" if $place || $name || $date;
    }
    return $label;
}

sub _extract_item_label {
    my ($self, $item) = @_;

    # Item label from Koha's items table
    my $location = $item->{location} || '';
    my $callno = $item->{callnumber} || '';
    my $barcode = $item->{barcode} || '';
    return "$location $callno ($barcode)" if $location || $callno;
    return $barcode if $barcode;
    return '';
}

sub _extract_work_properties {
    my ($self, $marc_record, $work_uri, $properties_ref) = @_;

    my $bffi_ns = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');

    # Title (from 245)
    if (my $field = $marc_record->field('245')) {
        if (my $title = $field->subfield('a')) {
            push @{$properties_ref->{$work_uri}}, {
                property_uri => "${bffi_ns}title",
                property_key => 'title',
                value_type => 'literal',
                value_text => $title,
            };
        }
    }

    # Uniform title (from 130/240)
    for my $tag (qw(130 240)) {
        if (my $field = $marc_record->field($tag)) {
            if (my $title = $field->subfield('a')) {
                push @{$properties_ref->{$work_uri}}, {
                    property_uri => "${bffi_ns}uniformTitle",
                    property_key => 'uniformTitle',
                    value_type => 'literal',
                    value_text => $title,
                };
                last;
            }
        }
    }

    # Classification (from 050, 080, 084)
    for my $tag (qw(050 080 084)) {
        if (my $field = $marc_record->field($tag)) {
            my $classification = join(' ', map { $_->[1] } $field->subfield('a'));
            if ($classification) {
                push @{$properties_ref->{$work_uri}}, {
                    property_uri => "${bffi_ns}classification",
                    property_key => 'classification',
                    value_type => 'literal',
                    value_text => $classification,
                };
            }
        }
    }

    # Work characteristics (from 380-386)
    for my $tag (380..386) {
        if (my $field = $marc_record->field($tag)) {
            my $value = join(' ', map { $_->[1] } $field->subfield('a'));
            if ($value) {
                push @{$properties_ref->{$work_uri}}, {
                    property_uri => "${bffi_ns}workCharacteristic",
                    property_key => 'workCharacteristic',
                    value_type => 'literal',
                    value_text => $value,
                };
            }
        }
    }

    # Language, original language and translation flag.
    # In the LoC 3-level stored model these sit on the Work.
    my $lang_result = $self->_detect_language($marc_record);
    if ($lang_result->{language}) {
        push @{$properties_ref->{$work_uri}}, {
            property_uri => "${bffi_ns}language",
            property_key => 'language',
            value_type => 'literal',
            value_text => $lang_result->{language},
        };
    }
    if ($lang_result->{original_language}) {
        push @{$properties_ref->{$work_uri}}, {
            property_uri => "${bffi_ns}originalLanguage",
            property_key => 'originalLanguage',
            value_type => 'literal',
            value_text => $lang_result->{original_language},
        };
    }
    if ($lang_result->{is_translation}) {
        push @{$properties_ref->{$work_uri}}, {
            property_uri => "${bffi_ns}isTranslation",
            property_key => 'isTranslation',
            value_type => 'literal',
            value_text => 'true',
        };
    }
}

sub _extract_instance_properties {
    my ($self, $marc_record, $instance_uri, $properties_ref) = @_;

    my $bffi_ns = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');

    # Edition (from 250) - Instance level in LoC
    if (my $field = $marc_record->field('250')) {
        if (my $edition = $field->subfield('a')) {
            push @{$properties_ref->{$instance_uri}}, {
                property_uri => "${bffi_ns}editionStatement",
                property_key => 'editionStatement',
                value_type => 'literal',
                value_text => $edition,
            };
        }
    }

    # Content type (from 336)
    if (my $field = $marc_record->field('336')) {
        if (my $content = $field->subfield('a')) {
            push @{$properties_ref->{$instance_uri}}, {
                property_uri => "${bffi_ns}contentType",
                property_key => 'contentType',
                value_type => 'literal',
                value_text => $content,
            };
        }
    }

    # Notes (from 500-546)
    for my $tag (500..546) {
        if (my $field = $marc_record->field($tag)) {
            my $note = join(' ', map { $_->[1] } $field->subfield('a'));
            if ($note) {
                push @{$properties_ref->{$instance_uri}}, {
                    property_uri => "${bffi_ns}note",
                    property_key => 'note',
                    value_type => 'literal',
                    value_text => $note,
                };
            }
        }
    }

    # Identifiers (from 020, 022, 024)
    for my $tag (qw(020 022 024)) {
        if (my $field = $marc_record->field($tag)) {
            my $id_type = ($tag eq '020') ? 'isbn' :
                         ($tag eq '022') ? 'issn' : 'identifier';
            my $value = $field->subfield('a') || '';
            if ($value) {
                push @{$properties_ref->{$instance_uri}}, {
                    property_uri => "${bffi_ns}identifier",
                    property_key => 'identifier',
                    value_type => 'literal',
                    value_text => $value,
                };
            }
        }
    }

    # Publication (from 260, 264)
    for my $tag (qw(260 264)) {
        if (my $field = $marc_record->field($tag)) {
            my $place = $field->subfield('a') || '';
            my $name = $field->subfield('b') || '';
            my $date = $field->subfield('c') || '';

            if ($place) {
                push @{$properties_ref->{$instance_uri}}, {
                    property_uri => "${bffi_ns}publicationPlace",
                    property_key => 'publicationPlace',
                    value_type => 'literal',
                    value_text => $place,
                };
            }
            if ($name) {
                push @{$properties_ref->{$instance_uri}}, {
                    property_uri => "${bffi_ns}publisherName",
                    property_key => 'publisherName',
                    value_type => 'literal',
                    value_text => $name,
                };
            }
            if ($date) {
                push @{$properties_ref->{$instance_uri}}, {
                    property_uri => "${bffi_ns}publicationDate",
                    property_key => 'publicationDate',
                    value_type => 'literal',
                    value_text => $date,
                };
            }
            last; # Use first occurrence
        }
    }

    # Extent (from 300)
    if (my $field = $marc_record->field('300')) {
        my $extent = join(' ', map { $_->[1] } $field->subfield('a'));
        if ($extent) {
            push @{$properties_ref->{$instance_uri}}, {
                property_uri => "${bffi_ns}extent",
                property_key => 'extent',
                value_type => 'literal',
                value_text => $extent,
            };
        }
    }

    # Media type (from 337)
    if (my $field = $marc_record->field('337')) {
        if (my $media = $field->subfield('a')) {
            push @{$properties_ref->{$instance_uri}}, {
                property_uri => "${bffi_ns}mediaType",
                property_key => 'mediaType',
                value_type => 'literal',
                value_text => $media,
            };
        }
    }

    # Carrier type (from 338)
    if (my $field = $marc_record->field('338')) {
        if (my $carrier = $field->subfield('a')) {
            push @{$properties_ref->{$instance_uri}}, {
                property_uri => "${bffi_ns}carrierType",
                property_key => 'carrierType',
                value_type => 'literal',
                value_text => $carrier,
            };
        }
    }

    # Series (from 490, 830)
    for my $tag (qw(490 830)) {
        if (my $field = $marc_record->field($tag)) {
            my $series = $field->subfield('a') || '';
            if ($series) {
                push @{$properties_ref->{$instance_uri}}, {
                    property_uri => "${bffi_ns}series",
                    property_key => 'series',
                    value_type => 'literal',
                    value_text => $series,
                };
                last;
            }
        }
    }

    # Electronic locator (from 856)
    if (my $field = $marc_record->field('856')) {
        if (my $url = $field->subfield('u')) {
            push @{$properties_ref->{$instance_uri}}, {
                property_uri => "${bffi_ns}electronicLocator",
                property_key => 'electronicLocator',
                value_type => 'resource',
                value_text => $url,
            };
        }
    }
}

sub store_items_from_koha {
    my ($self, $biblio_id, %options) = @_;

    my $base_uri = $self->{base_uri};
    my $dbh = $self->dbh;

    # Fetch items from Koha's authoritative items table
    my $sth = $dbh->prepare(
        "SELECT itemnumber, barcode, homebranch, holdingbranch, location, callnumber, itemlost
         FROM items
         WHERE biblionumber = ?"
    );
    $sth->execute($biblio_id);
    my $items = $sth->fetchall_arrayref({});

    my @resources_to_insert;
    my @links_to_insert;

    # Get the Instance resource for this biblio to link items to
    my $instance = $self->_find_instance_for_biblio($biblio_id);

    my $bffi_ns = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');

    for my $item (@$items) {
        my $itemnumber = $item->{itemnumber};
        my $item_uri = "${base_uri}item/$itemnumber";

        # Create minimal Item resource linking to Koha items.itemnumber
        push @resources_to_insert, {
            uri => $item_uri,
            resource_type => 'Item',
            biblio_id => $biblio_id,
            item_id => $itemnumber,
            label => $self->_extract_item_label($item),
            source_format => 'marc21',
        };

        # Link Instance to Item via hasItem/itemOf
        if ($instance) {
            push @links_to_insert, {
                source_uri => $instance->{uri},
                target_uri => $item_uri,
                relationship_type => 'hasItem',
                relationship_uri => "${bffi_ns}hasItem",
            };
            push @links_to_insert, {
                source_uri => $item_uri,
                target_uri => $instance->{uri},
                relationship_type => 'itemOf',
                relationship_uri => "${bffi_ns}itemOf",
            };
        }
    }

    return unless @resources_to_insert;

    # Store items (no properties - item data stays in Koha's items table)
    my $result = $self->_execute_storage(
        \@resources_to_insert,
        {},
        \@links_to_insert
    );

    return $result;
}

sub _find_instance_for_biblio {
    my ($self, $biblio_id) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT uri FROM record_resources
         WHERE biblio_id = ? AND resource_type IN ('Instance', 'Manifestation')
         LIMIT 1"
    );
    $sth->execute($biblio_id);
    return $sth->fetchrow_hashref();
}

sub _extract_agents {
    my ($self, $marc_record, $work_uri, $base_uri,
        $resources_ref, $properties_ref, $links_ref) = @_;

    my $bffi_ns = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');
    my %agent_fields = map { $_ => 1 } qw(100 110 111 700 710 711);

    for my $field ($marc_record->fields()) {
        my $tag = $field->tag();
        next unless exists $agent_fields{$tag};

        # Build agent name
        my $agent_name = '';
        my %agent_data;
        for my $subfield ($field->subfields()) {
            my ($code, $value) = @$subfield;
            next unless $value;
            $agent_data{$code} = $value;
            if ($code eq 'a' || ($code eq 'b' && $tag =~ /^1[01]0$/)) {
                $agent_name .= $value . ' ';
            }
        }
        $agent_name =~ s/\s+$//;
        next unless $agent_name;

        # Determine agent type
        my $agent_type = ($tag eq '110' || $tag eq '710') ? 'Organization' :
                        ($tag eq '111' || $tag eq '711') ? 'Meeting' : 'Person';

        # Generate agent URI (with dedup via normalization)
        my $normalized_name = $self->_normalize_agent_name($agent_name);
        my $agent_uri = "${base_uri}agent/" . $normalized_name;

        # Check if agent already exists
        my $existing_agent = $self->_find_existing_resource($agent_uri);

        unless ($existing_agent) {
            # Create new agent resource
            push @$resources_ref, {
                uri => $agent_uri,
                resource_type => $agent_type,
                label => $agent_name,
                label_normalized => $normalized_name,
                source_format => 'marc21',
            };

            # Add agent properties
            push @{$properties_ref->{$agent_uri}}, {
                property_uri => 'http://www.w3.org/2000/01/rdf-schema#label',
                property_key => 'label',
                value_type => 'literal',
                value_text => $agent_name,
            };

            # Add dates if present
            if (my $dates = $agent_data{d}) {
                push @{$properties_ref->{$agent_uri}}, {
                    property_uri => "${bffi_ns}date",
                    property_key => 'date',
                    value_type => 'literal',
                    value_text => $dates,
                };
            }
        }

        # Link work to agent
        my $rel_type = ($tag =~ /^(1[01]0)$/) ? 'creator' : 'contributor';
        push @$links_ref, {
            source_uri => $work_uri,
            target_uri => $agent_uri,
            relationship_type => $rel_type,
            relationship_uri => "${bffi_ns}${rel_type}",
        };
    }
}

sub _extract_subjects {
    my ($self, $marc_record, $work_uri, $base_uri,
        $resources_ref, $properties_ref, $links_ref) = @_;

    my $bffi_ns = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');

    for my $field ($marc_record->fields()) {
        my $tag = $field->tag();
        next unless $tag =~ /^(6[0-5]\d)$/;

        my $subject_term = $field->subfield('a') || '';
        next unless $subject_term;

        # Determine subject type
        my $subject_type = 'Topic';
        if ($tag =~ /^65[01]$/) {
            $subject_type = 'Topic';
        } elsif ($tag =~ /^655$/) {
            $subject_type = 'GenreForm';
        } elsif ($tag =~ /^65[12]$/) {
            $subject_type = 'Geographic';
        } elsif ($tag =~ /^648$/) {
            $subject_type = 'Temporal';
        }

        # Generate subject URI (with dedup)
        my $normalized_term = $self->_normalize_subject_term($subject_term);
        my $source = $field->subfield('2') || 'lcsh';
        my $subject_uri = "${base_uri}subject/" . $source . '/' . $normalized_term;

        # Check if subject already exists
        my $existing_subject = $self->_find_existing_resource($subject_uri);

        unless ($existing_subject) {
            # Create new subject resource
            push @$resources_ref, {
                uri => $subject_uri,
                resource_type => $subject_type,
                label => $subject_term,
                label_normalized => $normalized_term,
                source_format => 'marc21',
            };

            # Add subject properties
            push @{$properties_ref->{$subject_uri}}, {
                property_uri => 'http://www.w3.org/2004/02/skos/core#prefLabel',
                property_key => 'prefLabel',
                value_type => 'literal',
                value_text => $subject_term,
            };

            push @{$properties_ref->{$subject_uri}}, {
                property_uri => "${bffi_ns}source",
                property_key => 'source',
                value_type => 'literal',
                value_text => $source,
            };
        }

        # Link work to subject
        push @$links_ref, {
            source_uri => $work_uri,
            target_uri => $subject_uri,
            relationship_type => 'subject',
            relationship_uri => "${bffi_ns}subject",
        };
    }
}

sub _detect_language {
    my ($self, $marc_record) = @_;

    # Priority 1: MARC 041 $h (explicit original language)
    if (my $field_041 = $marc_record->field('041')) {
        if (my $subfield_h = $field_041->subfield('h')) {
            return {
                language => $field_041->subfield('a') || $subfield_h,
                original_language => $subfield_h,
                is_translation => 1,
                source => '041$h',
            };
        }
    }

    # Priority 2: MARC 008 positions 35-37 (main language)
    if (my $field_008 = $marc_record->field('008')) {
        my $data = $field_008->data();
        if (length($data) >= 38) {
            my $lang_008 = substr($data, 35, 3);
            $lang_008 =~ s/\s+$//;

            my $is_translation = 0;
            my $original_language = $lang_008;

            if (my $field_041 = $marc_record->field('041')) {
                my @subfields_a = $field_041->subfield('a');
                if (@subfields_a && $subfields_a[0] ne $lang_008) {
                    $is_translation = 1;
                }
            }

            return {
                language => $lang_008,
                original_language => $original_language,
                is_translation => $is_translation,
                source => '008',
            };
        }
    }

    return {
        language => undef,
        original_language => undef,
        is_translation => 0,
        source => 'none',
    };
}

sub _normalize_agent_name {
    my ($self, $name) = @_;

    # NACO-style normalization: lowercase, strip punctuation, sort particles
    my $normalized = lc($name);
    $normalized =~ s/[.,;:!?]//g;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+|\s+$//g;

    # Sort inverted names (Last, First -> First Last)
    if ($normalized =~ /^(\w+),\s+(.+)$/) {
        $normalized = "$2 $1";
    }

    return $normalized;
}

sub _normalize_subject_term {
    my ($self, $term) = @_;

    my $normalized = lc($term);
    $normalized =~ s/[.,;:!?]//g;
    $normalized =~ s/\s+/ /g;
    $normalized =~ s/^\s+|\s+$//g;

    return $normalized;
}

sub _find_existing_resource {
    my ($self, $uri) = @_;

    my $sth = $self->dbh->prepare(
        "SELECT id FROM record_resources WHERE uri = ? LIMIT 1"
    );
    $sth->execute($uri);
    return $sth->fetchrow_hashref();
}

# Rebuilds summary table rows for resources whose URIs were just stored.
# Accepts a hashref of uri => resource_type (or a list of resource URIs).
sub _rebuild_summaries {
    my ($self, $resource_uris) = @_;

    my $rebuilder = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SummaryRebuilder->new();

    for my $uri (keys %$resource_uris) {
        my $type = $resource_uris->{$uri};
        my $res = $self->_find_existing_resource($uri);
        next unless $res;

        if ($type eq 'Work') {
            $rebuilder->rebuild_work_summary($res->{id});
        } elsif ($type eq 'Instance' || $type eq 'Manifestation') {
            $rebuilder->rebuild_instance_summary($res->{id});
        } elsif (grep { $_ eq $type } qw(Person Organization Meeting Family)) {
            $rebuilder->rebuild_agent_summary($res->{id});
        }
    }
}

sub _execute_storage {
    my ($self, $resources_ref, $properties_ref, $links_ref, $control_number) = @_;

    my $dbh = $self->dbh;
    my %resource_ids = ();
    my $result = {
        resources_created => 0,
        properties_created => 0,
        links_created => 0,
        resource_ids => {},
    };

    eval {
        $dbh->begin_work();

        # 1. Insert resources and collect IDs
        my $sth_res = $dbh->prepare(
            "INSERT INTO record_resources (uri, resource_type, biblio_id, item_id, label, label_normalized, source_format)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id), updated_at = CURRENT_TIMESTAMP"
        );

        for my $res (@$resources_ref) {
            $sth_res->execute(
                $res->{uri},
                $res->{resource_type},
                $res->{biblio_id},
                $res->{item_id},
                $res->{label} || '',
                $res->{label_normalized} || $res->{label} || '',
                $res->{source_format} || 'marc21',
            );
            $resource_ids{$res->{uri}} = $dbh->last_insert_id(undef, undef, 'record_resources', 'id');
            $result->{resources_created}++;
        }

        # 2. Insert properties
        my $sth_prop = $dbh->prepare(
            "INSERT INTO record_properties (resource_id, property_uri, property_key, value_type, value_text, value_lang, value_datatype)
             VALUES (?, ?, ?, ?, ?, ?, ?)"
        );

        for my $res_uri (keys %$properties_ref) {
            my $resource_id = $resource_ids{$res_uri};
            next unless $resource_id;

            for my $prop (@{$properties_ref->{$res_uri}}) {
                # Resolve resource URI to ID if needed
                my $value_resource_id = undef;
                if ($prop->{value_type} eq 'resource' && $prop->{value_resource_uri}) {
                    $value_resource_id = $resource_ids{$prop->{value_resource_uri}};
                    unless ($value_resource_id) {
                        # Look up existing resource
                        my $existing = $self->_find_existing_resource($prop->{value_resource_uri});
                        $value_resource_id = $existing->{id} if $existing;
                    }
                }

                $sth_prop->execute(
                    $resource_id,
                    $prop->{property_uri},
                    $prop->{property_key},
                    $prop->{value_type},
                    $prop->{value_text},
                    $prop->{value_lang},
                    $prop->{value_datatype},
                );
                $result->{properties_created}++;
            }
        }

        # 3. Insert links
        my $sth_link = $dbh->prepare(
            "INSERT INTO record_links (source_resource_id, target_resource_id, relationship_type, relationship_uri)
             VALUES (?, ?, ?, ?)
             ON DUPLICATE KEY UPDATE id = id"
        );

        for my $link (@$links_ref) {
            my $source_id = $resource_ids{$link->{source_uri}};
            my $target_id = $resource_ids{$link->{target_uri}};

            # Look up existing resources if not in current batch
            unless ($source_id) {
                my $existing = $self->_find_existing_resource($link->{source_uri});
                $source_id = $existing->{id} if $existing;
            }
            unless ($target_id) {
                my $existing = $self->_find_existing_resource($link->{target_uri});
                $target_id = $existing->{id} if $existing;
            }

            next unless $source_id && $target_id;

            $sth_link->execute(
                $source_id,
                $target_id,
                $link->{relationship_type},
                $link->{relationship_uri},
            );
            $result->{links_created}++;
        }

        $dbh->commit();
    };

    if ($@) {
        $dbh->rollback();
        die "Storage failed: $@";
    }

    $result->{resource_ids} = \%resource_ids;
    return $result;
}

1;
