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
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::ComponentPartsSync;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::MarcGenerator;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex;
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

=head2 get_record

    my $record = $store->get_record(resource_id => $id);
    my $record = $store->get_record(biblio_id => $biblio_id);

Delegates to MarcGenerator to reconstruct the authoritative MARC21 record for
a resource (or biblio). Returns a MARC::Record object or undef.

=cut

sub get_record {
    my ($self, %args) = @_;

    my $gen = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::MarcGenerator->new();
    return $gen->get_record(%args);
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

    # Save the authoritative MARC copy so MarcGenerator can reconstruct it
    $self->_save_format_mapping($marc_record, $instance_uri);

    # Sync the stored biblio to the search index if ES sync is enabled
    $self->_sync_search_index($biblio_id) if $biblio_id;

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
        replace      - Replace the biblio's previous graph transactionally
        record_base_uri - URI prefix identifying resources local to this record
        serialized_data - Serialized RDF/XML representation to retain
        marc_record  - Authoritative MARC record to retain as a format mapping

    Returns:
    Hashref with resource_ids, graph_id, format mapping IDs, and counts


=cut

sub store_bibframe_rdf {
    my ($self, $triples, %options) = @_;

    my $biblio_id = $options{biblio_id};
    my $source_format = $options{source_format} || 'bibframe';
    my $replace = $options{replace} ? 1 : 0;
    my $record_base_uri = $options{record_base_uri};

    die 'replace storage requires biblio_id' if $replace && !defined $biblio_id;
    die 'triples must be an array reference' unless ref($triples) eq 'ARRAY';

    my %type_map = (
        'http://id.loc.gov/ontologies/bibframe/Work'         => 'Work',
        'http://id.loc.gov/ontologies/bibframe/Expression'   => 'Expression',
        'http://id.loc.gov/ontologies/bibframe/Instance'     => 'Instance',
        'http://id.loc.gov/ontologies/bibframe/Item'         => 'Item',
        'http://id.loc.gov/ontologies/bibframe/Agent'        => 'Agent',
        'http://id.loc.gov/ontologies/bibframe/Person'       => 'Person',
        'http://id.loc.gov/ontologies/bibframe/Organization' => 'Organization',
        'http://id.loc.gov/ontologies/bibframe/Meeting'      => 'Meeting',
        'http://id.loc.gov/ontologies/bibframe/Family'       => 'Family',
        'http://id.loc.gov/ontologies/bibframe/Topic'        => 'Topic',
        'http://id.loc.gov/ontologies/bibframe/GenreForm'    => 'GenreForm',
        'http://id.loc.gov/ontologies/bibframe/Geographic'   => 'Geographic',
        'http://id.loc.gov/ontologies/bibframe/Temporal'     => 'Temporal',
        'http://id.loc.gov/ontologies/bibframe/Title'        => 'Title',
        'http://id.loc.gov/ontologies/bibframe/Place'        => 'Place',
        'http://id.loc.gov/ontologies/bibframe/Language'     => 'Language',
        'http://id.loc.gov/ontologies/bibframe/Series'       => 'Series',
        'http://id.loc.gov/ontologies/bibframe/AdminMetadata' => 'AdminMetadata',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Work'          => 'Work',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Expression'    => 'Expression',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Manifestation' => 'Manifestation',
        'http://urn.fi/URN:NBN:fi:schema:bffi:Item'          => 'Item',
    );

    my %type_priority = (
        Agent => 100,
        Work => 20,
        Expression => 20,
        Instance => 20,
        Manifestation => 20,
        Item => 20,
        Person => 50,
        Organization => 50,
        Meeting => 50,
        Family => 50,
        Topic => 50,
        GenreForm => 50,
        Geographic => 50,
        Temporal => 50,
        Title => 50,
        Place => 50,
        Language => 50,
        Series => 50,
        AdminMetadata => 50,
    );

    my %relationship_map = map { $_ => $_ } qw(
        hasExpression expressionOf manifestationOfExpression expressionManifested
        hasInstance instanceOf hasItem itemOf contribution subject partOf hasPart
        agent creator contributor
    );

    my (%types_by_subject, %labels, %label_priorities, %sequence);
    my (%agent_of_subject, %pending_role_by_subject, %agent_role);
    my $remember_agent_role = sub {
        my ($subject, $agent, $role) = @_;
        if (my $existing = $agent_role{$subject}{$agent}) {
            my $existing_rel = $self->_role_relationship_type($existing);
            my $new_rel = $self->_role_relationship_type($role);
            return if ($existing_rel || '') eq 'creator';
            return unless ($new_rel || '') eq 'creator';
        }
        $agent_role{$subject}{$agent} = $role;
    };
    for my $triple (@$triples) {
        next unless defined $triple->{subject} && !ref($triple->{subject});
        my $subject = $triple->{subject};
        my $predicate = $triple->{predicate} || '';
        my $object_type = $triple->{object_type} || 'literal';
        my $object = $triple->{object};

        if ($self->_is_rdf_type($predicate) && $object_type eq 'uri' && defined $object && !ref($object)) {
            my $resource_type = $type_map{$object};
            next unless $resource_type;
            my $priority = $type_priority{$resource_type} || 100;
            if (!$types_by_subject{$triple->{subject}}
                || $priority < $types_by_subject{$triple->{subject}}{priority}) {
                $types_by_subject{$triple->{subject}} = {
                    type => $resource_type,
                    priority => $priority,
                };
            }
        }

        my ($localname) = $predicate =~ m{(?:^|:|/|#)([^/:]+)$};
        next unless defined $localname;

        # An agent and its role(s) are adjacent properties of the same subject
        # (bf:contribution/bf:Contribution flattens onto the parent resource).
        # Any other property in between breaks the pairing, so adminMetadata
        # agents can never pick up a contribution role emitted elsewhere.
        if ($localname ne 'agent' && $localname ne 'role') {
            delete $agent_of_subject{$subject};
            delete $pending_role_by_subject{$subject};
        }

        if ($object_type eq 'uri' && defined $object && !ref($object)) {
            if ($localname eq 'agent') {
                if (my $role = delete $pending_role_by_subject{$subject}) {
                    $remember_agent_role->($subject, $object, $role);
                }
                $agent_of_subject{$subject} = $object;
            } elsif ($localname eq 'role') {
                if ($agent_of_subject{$subject}) {
                    $remember_agent_role->($subject, $agent_of_subject{$subject}, $object);
                } else {
                    $pending_role_by_subject{$subject} = $object;
                }
            }
        }
        next if $object_type ne 'literal' || !defined $object || ref($object);
        my $priority;
        if ($localname eq 'mainTitle') {
            # Beats rdfs:label: flattened anonymous nodes (bf:Note etc.) can
            # contribute their own rdfs:label to the parent resource.
            $priority = 110;
        } elsif ($predicate eq 'rdfs:label' || $predicate =~ /\/label$/) {
            $priority = 100;
        } elsif ($localname eq 'title') {
            $priority = 80;
        } elsif ($localname eq 'prefLabel') {
            $priority = 70;
        } elsif ($localname eq 'code') {
            $priority = 60;
        }
        if ($priority && (!defined $label_priorities{$triple->{subject}}
            || $priority > $label_priorities{$triple->{subject}})) {
            $labels{$triple->{subject}} = substr($object, 0, 1024);
            $label_priorities{$triple->{subject}} = $priority;
        }
    }

    my %resources_to_insert;
    for my $uri (keys %types_by_subject) {
        my $shared = defined($biblio_id)
            && defined($record_base_uri)
            && index($uri, $record_base_uri) != 0;
        my $label = $labels{$uri} || '';
        $resources_to_insert{$uri} = {
            uri => $uri,
            resource_type => $types_by_subject{$uri}{type},
            biblio_id => $shared ? undef : $biblio_id,
            label => $label,
            label_normalized => lc($label),
            source_format => $source_format,
            shared => $shared,
        };
    }

    die 'BIBFRAME triples contained no supported resources' unless %resources_to_insert;

    my @properties_to_insert;
    my @links_to_insert;
    for my $triple (@$triples) {
        my $subject = $triple->{subject};
        next unless defined $subject && exists $resources_to_insert{$subject};

        my $predicate = $triple->{predicate} || '';
        my $object = $triple->{object};
        my $object_type = $triple->{object_type} || 'literal';
        next if $self->_is_rdf_type($predicate);
        next unless defined $object && !ref($object);

        my ($localname) = $predicate =~ m{(?:^|:|/|#)([^/:]+)$};
        next unless defined $localname;

        my $relationship_type = $relationship_map{$localname};
        if ($localname eq 'agent' && $agent_role{$subject}{$object}) {
            $relationship_type = $self->_role_relationship_type($agent_role{$subject}{$object})
                || $relationship_type;
        }
        if ($object_type eq 'uri' && $relationship_type && exists $resources_to_insert{$object}) {
            push @links_to_insert, {
                source_uri => $subject,
                target_uri => $object,
                relationship_type => $relationship_type,
                relationship_uri => $self->_expand_predicate_uri($predicate),
            };
            next;
        }

        my $value_type = $object_type eq 'uri' ? 'resource'
            : $object_type eq 'bnode' ? 'bnode'
            : 'literal';
        my $sequence = $sequence{$subject}++;
        push @properties_to_insert, {
            resource_uri => $subject,
            property_uri => $self->_expand_predicate_uri($predicate),
            property_key => $localname,
            value_type => $value_type,
            value_text => $object,
            value_resource_uri => $value_type eq 'resource' ? $object : undef,
            value_lang => $triple->{lang},
            value_datatype => $triple->{datatype},
            sequence => $sequence,
        };
    }

    my $serialized_data = $options{serialized_data};
    unless (defined $serialized_data) {
        my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
        $serialized_data = $db->serializeTriples($triples, 'rdfxml');
    }

    my $result = $self->_execute_bibframe_storage(
        [values %resources_to_insert],
        \@properties_to_insert,
        \@links_to_insert,
        biblio_id => $biblio_id,
        replace => $replace,
        serialized_data => $serialized_data,
        marc_record => $options{marc_record},
    );

    my %summary_types = map { $_->{uri} => $_->{resource_type} } values %resources_to_insert;
    my $summary_result = eval { $self->_rebuild_summaries(\%summary_types); 1 };
    unless ($summary_result) {
        my $error = $@ || 'unknown summary rebuild failure';
        chomp $error;
        push @{ $result->{warnings} }, "summary rebuild failed: $error";
        warn "BIBFRAME summary rebuild failed: $error\n";
    }
    if ($biblio_id) {
        my $search_result = eval { $self->_sync_search_index($biblio_id); 1 };
        unless ($search_result) {
            my $error = $@ || 'unknown search synchronization failure';
            chomp $error;
            push @{ $result->{warnings} }, "search synchronization failed: $error";
            warn "BIBFRAME search synchronization failed: $error\n";
        }
    }

    return $result;
}

=head1 PRIVATE METHODS

=cut

sub _role_relationship_type {
    my ($self, $role) = @_;

    return undef unless defined $role;
    $role =~ s/[?#].*$//;
    my ($code) = $role =~ m{/([^/]+)$};
    return undef unless defined $code;
    $code = lc $code;
    return 'creator' if $code =~ /^(?:aut|cre|author|creator)$/;
    return 'contributor' if $code =~ /^(?:ctb|contributor|contribution)$/;
    return undef;
}

sub _is_rdf_type {
    my ($self, $predicate) = @_;

    return 0 unless defined $predicate;
    return 1 if $predicate eq 'rdf:type';
    return 1 if $predicate eq 'http://www.w3.org/1999/02/22-rdf-syntax-ns#type';
    return 0;
}

sub _expand_predicate_uri {
    my ($self, $predicate) = @_;

    return undef unless defined $predicate;
    return $predicate if $predicate =~ m{^https?://};

    my %namespaces = (
        rdf => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
        rdfs => 'http://www.w3.org/2000/01/rdf-schema#',
        owl => 'http://www.w3.org/2002/07/owl#',
        bf => 'http://id.loc.gov/ontologies/bibframe#',
        bffi => 'http://urn.fi/URN:NBN:fi:schema:bffi:',
        bflc => 'http://id.loc.gov/ontologies/bflc#',
        dcterms => 'http://purl.org/dc/terms/',
        dct => 'http://purl.org/dc/elements/1.1/',
        skos => 'http://www.w3.org/2004/02/skos/core#',
        foaf => 'http://xmlns.com/foaf/0.1/',
        lclocal => 'http://id.loc.gov/ontologies/lclocal/',
    );

    if ($predicate =~ m{^([A-Za-z][A-Za-z0-9_-]*):(.+)$} && $namespaces{$1}) {
        return $namespaces{$1} . $2;
    }
    return $predicate;
}

sub _execute_bibframe_storage {
    my (
        $self,
        $resources_ref,
        $properties_ref,
        $links_ref,
        %options
    ) = @_;

    my $biblio_id = $options{biblio_id};
    my $replace = $options{replace} ? 1 : 0;
    my $result = {
        resources_stored => 0,
        properties_stored => 0,
        links_stored => 0,
        resources_created => 0,
        properties_created => 0,
        links_created => 0,
        resource_id_by_uri => {},
        warnings => [],
    };
    my $dbh = $self->dbh;

    eval {
        $dbh->begin_work;

    my $graph_id;
    if (defined $biblio_id) {
        my $graph_sth = $dbh->prepare(q{
            INSERT INTO record_graphs (biblio_id, graph_type)
            VALUES (?, 'bibframe')
            ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id),
                graph_type = VALUES(graph_type),
                updated_at = CURRENT_TIMESTAMP
        });
        $graph_sth->execute($biblio_id);
        $graph_id = $dbh->last_insert_id;
        $graph_sth->finish;
    }

    my @previous_shared_ids;
    if ($replace && defined $graph_id) {
        my $shared_sth = $dbh->prepare(q{
            SELECT r.id
            FROM record_graph_resources gr
            JOIN record_resources r ON r.id = gr.resource_id
            WHERE gr.graph_id = ?
              AND r.biblio_id IS NULL
        });
        $shared_sth->execute($graph_id);
        while (my $row = $shared_sth->fetchrow_hashref()) {
            push @previous_shared_ids, $row->{id};
        }
        $shared_sth->finish;
    }

    if ($replace && defined $biblio_id) {
        my $membership_sth = $dbh->prepare(q{
            DELETE FROM record_graph_resources
            WHERE graph_id = ?
        });
        $membership_sth->execute($graph_id);
        $membership_sth->finish;

        my $resource_sth = $dbh->prepare(q{
            DELETE FROM record_resources
            WHERE biblio_id = ?
        });
        $resource_sth->execute($biblio_id);
        $resource_sth->finish;
    }

    my $resource_sth = $dbh->prepare(q{
        INSERT INTO record_resources
            (uri, resource_type, biblio_id, item_id, label, label_normalized, source_format)
        VALUES (?, ?, ?, NULL, ?, ?, ?)
        ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id),
            resource_type = VALUES(resource_type),
            biblio_id = IF(?, NULL, VALUES(biblio_id)),
            item_id = COALESCE(VALUES(item_id), item_id),
            label = IF(VALUES(label) = '', label, VALUES(label)),
            label_normalized = IF(VALUES(label_normalized) = '', label_normalized, VALUES(label_normalized)),
            source_format = VALUES(source_format),
            updated_at = CURRENT_TIMESTAMP
    });

    my %resource_id_by_uri;
    for my $resource (@$resources_ref) {
        $resource_sth->execute(
            $resource->{uri},
            $resource->{resource_type},
            $resource->{biblio_id},
            defined($resource->{label}) ? $resource->{label} : '',
            defined($resource->{label_normalized}) ? $resource->{label_normalized} : '',
            defined($resource->{source_format}) ? $resource->{source_format} : 'bibframe',
            $resource->{shared} ? 1 : 0,
        );
        my $resource_id = $dbh->last_insert_id;
        $resource_id_by_uri{$resource->{uri}} = $resource_id;
        $result->{resource_id_by_uri}{$resource->{uri}} = $resource_id;
        $result->{resources_stored}++;
        $result->{resources_created}++;
    }
    $resource_sth->finish;

    if (@previous_shared_ids) {
        my %current_resource_ids = map { $_ => 1 } values %resource_id_by_uri;
        my $other_graph_count_sth = $dbh->prepare(q{
            SELECT COUNT(*)
            FROM record_graph_resources
            WHERE resource_id = ?
              AND graph_id <> ?
        });
        my $delete_properties_sth = $dbh->prepare(q{
            DELETE FROM record_properties
            WHERE resource_id = ?
        });
        my $delete_links_sth = $dbh->prepare(q{
            DELETE FROM record_links
            WHERE source_resource_id = ?
               OR target_resource_id = ?
        });
        my $delete_resource_sth = $dbh->prepare(q{
            DELETE FROM record_resources
            WHERE id = ?
              AND biblio_id IS NULL
        });
        for my $resource_id (@previous_shared_ids) {
            $other_graph_count_sth->execute($resource_id, $graph_id);
            my ($other_count) = $other_graph_count_sth->fetchrow_array;
            $other_graph_count_sth->finish;
            next if $other_count;

            if ($current_resource_ids{$resource_id}) {
                $delete_properties_sth->execute($resource_id);
                $delete_links_sth->execute($resource_id, $resource_id);
            } else {
                $delete_resource_sth->execute($resource_id);
            }
        }
        $other_graph_count_sth->finish;
        $delete_properties_sth->finish;
        $delete_links_sth->finish;
        $delete_resource_sth->finish;
    }

    my $property_sth = $dbh->prepare(q{
        INSERT INTO record_properties
            (resource_id, property_uri, property_key, value_type,
             value_resource_id, value_text, value_lang, value_datatype, sequence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
    my $property_exists_sth = $dbh->prepare(q{
        SELECT id
        FROM record_properties
        WHERE resource_id = ?
          AND property_uri = ?
          AND property_key = ?
          AND value_type = ?
          AND value_resource_id <=> ?
          AND value_text <=> ?
          AND value_lang <=> ?
          AND value_datatype <=> ?
        LIMIT 1
    });
    for my $property (@$properties_ref) {
        my $resource_id = $resource_id_by_uri{$property->{resource_uri}};
        next unless $resource_id;
        my $value_resource_id = $property->{value_resource_uri}
            ? $resource_id_by_uri{$property->{value_resource_uri}}
            : undef;
        $property_exists_sth->execute(
            $resource_id,
            $property->{property_uri},
            $property->{property_key},
            $property->{value_type},
            $value_resource_id,
            $property->{value_text},
            $property->{value_lang},
            $property->{value_datatype},
        );
        next if $property_exists_sth->fetchrow_arrayref;
        $property_sth->execute(
            $resource_id,
            $property->{property_uri},
            $property->{property_key},
            $property->{value_type},
            $value_resource_id,
            $property->{value_text},
            $property->{value_lang},
            $property->{value_datatype},
            defined($property->{sequence}) ? $property->{sequence} : 0,
        );
        $result->{properties_stored}++;
        $result->{properties_created}++;
    }
    $property_exists_sth->finish;
    $property_sth->finish;

    my $link_sth;
    if (@$links_ref) {
        $link_sth = $dbh->prepare(q{
            INSERT INTO record_links
                (source_resource_id, target_resource_id, relationship_type, relationship_uri)
            VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id),
                relationship_uri = VALUES(relationship_uri),
                updated_at = CURRENT_TIMESTAMP
        });
        for my $link (@$links_ref) {
            my $source_id = $resource_id_by_uri{$link->{source_uri}};
            my $target_id = $resource_id_by_uri{$link->{target_uri}};
            next unless $source_id && $target_id;
            $link_sth->execute(
                $source_id,
                $target_id,
                $link->{relationship_type},
                $link->{relationship_uri},
            );
            $result->{links_stored}++;
            $result->{links_created}++;
        }
        $link_sth->finish;
    }

    if (defined $graph_id) {
        my $membership_sth = $dbh->prepare(q{
            INSERT INTO record_graph_resources
                (graph_id, resource_id, role)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE role = VALUES(role)
        });
        for my $resource (@$resources_ref) {
            my $resource_id = $resource_id_by_uri{$resource->{uri}};
            next unless $resource_id;
            $membership_sth->execute($graph_id, $resource_id, lc($resource->{resource_type}));
        }
        $membership_sth->finish;
    }

    if (defined $biblio_id && defined $options{serialized_data}) {
        my ($primary_resource) = grep {
            ($_->{resource_type} || '') eq 'Instance'
                || ($_->{resource_type} || '') eq 'Manifestation'
        } @$resources_ref;
        $primary_resource ||= (grep { ($_->{resource_type} || '') eq 'Work' } @$resources_ref)[0];
        $primary_resource ||= ($resources_ref->[0]);
        if ($primary_resource) {
            my $mapping_resource_id = $resource_id_by_uri{$primary_resource->{uri}};
            my $mapping_id = $self->_upsert_format_mapping(
                $mapping_resource_id,
                'bibframe2',
                $options{serialized_data},
                undef,
            );
            $result->{format_mapping_id} = $mapping_id;
            $result->{primary_resource_id} = $mapping_resource_id;
        }

        if ($options{marc_record}) {
            my $marc_xml = eval { $options{marc_record}->as_xml };
            if (defined $marc_xml) {
                my $marc_tags = $self->_extract_marc_tags_json($options{marc_record});
                $result->{marc_format_mapping_id} = $self->_upsert_format_mapping(
                    $result->{primary_resource_id},
                    'marc21',
                    $marc_xml,
                    $marc_tags,
                );
            }
        }
    }

        $dbh->commit;
        $result->{graph_id} = $graph_id;
        1;
    };

    if ($@) {
        my $error = $@;
        eval { $dbh->rollback };
        die "BIBFRAME storage failed: $error";
    }

    return $result;
}

sub _upsert_format_mapping {
    my ($self, $resource_id, $format_name, $serialized_data, $marc_tags_json) = @_;

    return undef unless $resource_id;
    my $sth = $self->dbh->prepare(q{
        INSERT INTO record_format_mappings
            (resource_id, format_name, serialized_data, marc_tags_json, version)
        VALUES (?, ?, ?, ?, 1)
        ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id),
            resource_id = VALUES(resource_id),
            format_name = VALUES(format_name),
            serialized_data = VALUES(serialized_data),
            marc_tags_json = VALUES(marc_tags_json),
            version = version + 1,
            updated_at = CURRENT_TIMESTAMP
    });
    $sth->execute($resource_id, $format_name, $serialized_data, $marc_tags_json);
    my $mapping_id = $self->dbh->last_insert_id;
    $sth->finish;
    return $mapping_id;
}

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
            my $classification = join(' ', $field->subfield('a'));
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
            my $value = join(' ', $field->subfield('a'));
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
            my $note = join(' ', $field->subfield('a'));
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
        my $extent = join(' ', $field->subfield('a'));
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
    my $parts_sync = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::ComponentPartsSync->new();

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

        # Keep the materialized component-parts table in sync for any resource
        # that may participate in a partOf/hasPart containment link.
        $parts_sync->sync_for_resource($res->{id});
    }
}

# Syncs a biblio's document to the Elasticsearch search index when enabled.
# ES failures are swallowed so the storage transaction is not affected.
sub _sync_search_index {
    my ($self, $biblio_id) = @_;

    return unless $biblio_id;

    my $search = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SearchIndex->new();
    return unless $search->sync_enabled();

    try {
        $search->index_document($biblio_id);
    } catch {
        warn "Search index sync for biblio $biblio_id failed: $_";
    };
}

# Persists the authoritative MARC21 copy to record_format_mappings so that
# MarcGenerator can reconstruct it. The MARC copy is per-biblio; it is keyed
# to the resource id of the given resource URI (the Instance for a biblio).
sub _save_format_mapping {
    my ($self, $marc_record, $resource_uri) = @_;

    return unless $marc_record && $resource_uri;

    my $res = $self->_find_existing_resource($resource_uri);
    return unless $res;

    my $xml = $marc_record->as_xml();

    $self->_upsert_format_mapping(
        $res->{id},
        'marc21',
        $xml,
        $self->_extract_marc_tags_json($marc_record),
    );
}

# Collects the MARC tags used in the record as JSON, for introspection/rebuild.
sub _extract_marc_tags_json {
    my ($self, $marc_record) = @_;

    my %tags;
    for my $field ($marc_record->fields()) {
        $tags{$field->tag()} = 1;
    }

    my @sorted = sort keys %tags;
    return encode_json(\@sorted);
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
            "INSERT INTO record_properties (resource_id, property_uri, property_key, value_type, value_resource_id, value_text, value_lang, value_datatype)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
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
                    $value_resource_id,
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
