package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;

use strict;
use warnings;
use Try::Tiny;
use MARC::Record;
use MARC::File::XML;
use XML::LibXML;
use XML::LibXSLT;
use File::Basename;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping;

# Bibframe Namespaces (imported from Mapping)
our $Bibframe_NS = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bffi');
our $BF_NS = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('bf');
our $RDAW_NS = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('rdaw');
our $RDAE_NS = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('rdae');
our $RDAM_NS = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('rdam');
our $RDAI_NS = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_namespace('rdai');

# Constructor
sub new {
    my ($class, %args) = @_;
    my $self = bless {
        mapping => \%Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::,
    }, $class;
    return $self;
}

# Field categorization - dynamically built from Mapping
our %WORK_FIELDS = map { $_ => 1 } keys %{$Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::MARC21_TO_WORK};
our %EXPRESSION_FIELDS = map { $_ => 1 } keys %{$Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::MARC21_TO_EXPRESSION};
our %MANIFESTATION_FIELDS = map { $_ => 1 } keys %{$Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::MARC21_TO_MANIFESTATION};
our %ITEM_FIELDS = map { $_ => 1 } keys %{$Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::MARC21_TO_ITEM};
# The agents, such as persons or organizations
our %AGENT_FIELDS = map { $_ => 1 } qw(100 110 111 700 710 711);
our %AGENT_SUBFIELDS = map { $_ => 1 } qw(a b c d e q);

sub map_work_entities {
    my ($self, $marc_record) = @_;
    my @works;
    try {
        foreach my $field ($marc_record->fields()) {
            my $tag = $field->tag();
            next unless exists $WORK_FIELDS{$tag};

            my %work;
            foreach my $subfield ($field->subfields()) {
                my ($code, $value) = @$subfield;
                $work{$tag}{$code} = $value;
            }
            push @works, \%work;
        }
    }
    catch {
        warn "Error mapping work entities: $_";
    };
    return \@works;
}

sub map_expression_entities {
    my ($self, $marc_record) = @_;
    my @expressions;
    
    try {
        foreach my $field ($marc_record->fields()) {
            my $tag = $field->tag();
            next unless exists $EXPRESSION_FIELDS{$tag};

            my %expression;
            foreach my $subfield ($field->subfields()) {
                my ($code, $value) = @$subfield;
                $expression{$tag}{$code} = $value;
            }
            push @expressions, \%expression;
        }
    }
    catch {
        warn "Error mapping expression entities: $_";
    };
    return \@expressions;
}

sub map_manifestation_entities {
    my ($self, $marc_record) = @_;
    my @manifestations;

    try {
        foreach my $field ($marc_record->fields()) {
            my $tag = $field->tag();
            next unless exists $MANIFESTATION_FIELDS{$tag};

            my %manifestation;
            foreach my $subfield ($field->subfields()) {
                my ($code, $value) = @$subfield;
                $manifestation{$tag}{$code} = $value;
            }
            push @manifestations, \%manifestation;
        }
    }
    catch {
        warn "Error mapping manifestation entities: $_";
    };
    return \@manifestations;
}

sub map_instance_entities {
    my ($self, $marc_record) = @_;
    # Legacy method - now calls manifestation entities
    return $self->map_manifestation_entities($marc_record);
}

sub map_agent_entities {
    my ($self, $marc_record) = @_;
    my @agents;

    try {
        foreach my $field ($marc_record->fields()) {
            my $tag = $field->tag();
            next unless exists $AGENT_FIELDS{$tag};

            my %agent;
            foreach my $subfield ($field->subfields()) {
                my ($code, $value) = @$subfield;
                next unless exists $AGENT_SUBFIELDS{$code};
                $agent{$tag}{$code} = $value;
            }
            push @agents, \%agent;
        }
    }
    catch {
        warn "Error mapping agent entities: $_";
    };
    return \@agents;
}

sub convert_record_to_bibframe {
    my ($self, $marc_record) = @_;
    my @triples;

    my $control_number = $marc_record->field('001') ? $marc_record->field('001')->data() : 'unknown';
    my $work_uri     = "http://id.loc.gov/resources/works/" . $control_number;
    my $instance_uri = "http://id.loc.gov/resources/instances/" . $control_number;
    
    # Add type declarations
    push @triples, {
        subject     => $work_uri,
        predicate   => 'rdf:type',
        object      => $BF_NS . 'Work',
        object_type => 'uri',
    };
    
    push @triples, {
        subject     => $instance_uri,
        predicate   => 'rdf:type',
        object      => $BF_NS . 'Instance',
        object_type => 'uri',
    };
    
    # Link Work to Instance
    push @triples, {
        subject     => $instance_uri,
        predicate   => $BF_NS . 'instanceOf',
        object      => $work_uri,
        object_type => 'uri',
    };
    
    # Map Work entities using Mapping (using BIBFRAME properties)
    my $works = $self->map_work_entities($marc_record);
    foreach my $work (@$works) {
        foreach my $tag (keys %$work) {
            my $mapping = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_work_mapping($tag);
            my $bibframe_predicate = $mapping ? $mapping->{property} : $BF_NS . 'note';
            
            foreach my $code (keys %{$work->{$tag}}) {
                my $value = $work->{$tag}{$code};
                push @triples, {
                    subject     => $work_uri,
                    predicate   => $bibframe_predicate,
                    object      => $value,
                    object_type => 'literal',
                };
            }
        }
    }
    
    # Map Instance (Manifestation) entities
    my $instances = $self->map_instance_entities($marc_record);
    foreach my $instance (@$instances) {
        foreach my $tag (keys %$instance) {
            my $mapping = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_manifestation_mapping($tag);
            my $bibframe_predicate = $mapping ? $mapping->{property} : $BF_NS . 'note';
            
            foreach my $code (keys %{$instance->{$tag}}) {
                my $value = $instance->{$tag}{$code};
                push @triples, {
                    subject     => $instance_uri,
                    predicate   => $bibframe_predicate,
                    object      => $value,
                    object_type => 'literal',
                };
            }
        }
    }
    
    # Map Agents using enhanced mapping
    my $agents = $self->map_agent_entities($marc_record);
    foreach my $agent (@$agents) {
        my $agent_name = '';
        my $agent_tag;
        
        foreach my $tag (keys %$agent) {
            $agent_tag = $tag;
            foreach my $code (keys %{$agent->{$tag}}) {
                $agent_name .= $agent->{$tag}{$code} . " ";
            }
        }
        
        $agent_name =~ s/\s+$//;
        next unless $agent_name;
        
        my $agent_uri = "http://id.loc.gov/rwo/agents/" . $agent_name;
        $agent_uri =~ s/[\s,]+/_/g;
        
        push @triples, {
            subject     => $work_uri,
            predicate   => $BF_NS . 'contribution',
            object      => $agent_uri,
            object_type => 'uri',
        };
        
        push @triples, {
            subject     => $agent_uri,
            predicate   => 'rdfs:label',
            object      => $agent_name,
            object_type => 'literal',
        };
        
        # Add agent type
        my $agent_type = ($agent_tag eq '110' || $agent_tag eq '710') ? 'Organization' :
                        ($agent_tag eq '111' || $agent_tag eq '711') ? 'Meeting' : 'Person';
        push @triples, {
            subject     => $agent_uri,
            predicate   => 'rdf:type',
            object      => $BF_NS . $agent_type,
            object_type => 'uri',
        };
    }

    return \@triples;
}

sub convert_record_to_Bibframe {
    my ($self, $marc_record, %options) = @_;
    my @triples;

    # Generate URIs for Work, Expression, Manifestation levels
    my $control_number = $marc_record->field('001') ? $marc_record->field('001')->data() : 'unknown';
    my $base_uri = $options{base_uri} || 'http://urn.fi/URN:NBN:fi:bib:';
    
    my $work_uri = "${base_uri}work/${control_number}";
    my $expression_uri = "${base_uri}expression/${control_number}";
    my $manifestation_uri = "${base_uri}manifestation/${control_number}";
    my $item_uri = "${base_uri}item/${control_number}";

    # Add RDF type declarations
    push @triples, {
        subject     => $work_uri,
        predicate   => 'rdf:type',
        object      => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_class_uri('Work'),
        object_type => 'uri',
    };
    
    push @triples, {
        subject     => $expression_uri,
        predicate   => 'rdf:type',
        object      => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_class_uri('Expression'),
        object_type => 'uri',
    };
    
    push @triples, {
        subject     => $manifestation_uri,
        predicate   => 'rdf:type',
        object      => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_class_uri('Manifestation'),
        object_type => 'uri',
    };

    # Link Work -> Expression -> Manifestation using Mapping relationships
    push @triples, {
        subject     => $work_uri,
        predicate   => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_relationship_uri('hasExpression'),
        object      => $expression_uri,
        object_type => 'uri',
    };
    
    push @triples, {
        subject     => $expression_uri,
        predicate   => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_relationship_uri('expressionOf'),
        object      => $work_uri,
        object_type => 'uri',
    };
    
    push @triples, {
        subject     => $expression_uri,
        predicate   => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_relationship_uri('manifestationOfExpression'),
        object      => $manifestation_uri,
        object_type => 'uri',
    };
    
    push @triples, {
        subject     => $manifestation_uri,
        predicate   => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_relationship_uri('expressionManifested'),
        object      => $expression_uri,
        object_type => 'uri',
    };

    # Map Work entities using detailed Mapping
    push @triples, @{$self->_map_level_with_mapping(
        $marc_record, $work_uri, 'work', \%WORK_FIELDS
    )};

    # Map Expression entities using detailed Mapping
    push @triples, @{$self->_map_level_with_mapping(
        $marc_record, $expression_uri, 'expression', \%EXPRESSION_FIELDS
    )};

    # Map Manifestation entities using detailed Mapping
    push @triples, @{$self->_map_level_with_mapping(
        $marc_record, $manifestation_uri, 'manifestation', \%MANIFESTATION_FIELDS
    )};

    # Map Item entities using detailed Mapping
    push @triples, @{$self->_map_level_with_mapping(
        $marc_record, $item_uri, 'item', \%ITEM_FIELDS
    )};

    # Map Agents (contributors/creators) using enhanced mapping
    push @triples, @{$self->_map_agents_with_mapping(
        $marc_record, $work_uri, $base_uri
    )};

    return \@triples;
}

# New helper method to map entities using Mapping configuration
sub _map_level_with_mapping {
    my ($self, $marc_record, $subject_uri, $level, $field_hash) = @_;
    my @triples;
    
    # Get the appropriate mapping function based on level
    my %mapping_funcs = (
        work          => \&Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_work_mapping,
        expression    => \&Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_expression_mapping,
        manifestation => \&Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_manifestation_mapping,
        item          => \&Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_item_mapping,
    );
    
    my $mapping_func = $mapping_funcs{$level};
    unless ($mapping_func) {
        warn "No mapping function found for level: $level";
        return \@triples;
    }
    
    foreach my $field ($marc_record->fields()) {
        my $tag = $field->tag();
        next unless exists $field_hash->{$tag};
        
        my $mapping = $mapping_func->($tag);
        next unless $mapping;
        
        # Handle the main property
        my $property = $mapping->{property};
        my $object_type = $mapping->{type};
        my $subproperties = $mapping->{subproperties} || {};
        
        # Skip if no property defined
        next unless $property;
        
        # Check if this field maps to an external authority (subjects, agents)
        # Fields 6XX and 7XX often reference external authorities
        my $is_authority_field = ($tag =~ /^(6\d\d|7[0-7]\d)$/);
        
        # Build a property node URI from the field data
        my $node_label = '';
        foreach my $subfield ($field->subfields()) {
            my ($code, $value) = @$subfield;
            # Use main subfields (a, b, c) for URI construction
            if ($code =~ /^[abc]$/ && $value) {
                $node_label .= $value . '_';
            }
        }
        
        $node_label = 'node' unless $node_label; # Fallback if no suitable subfields

        # Sanitize: replace problematic characters
        $node_label =~ s/[\s,\.;:]+/_/g;
        $node_label =~ s/[^\w:\/\-_.]/_/g;
        $node_label =~ s/_+/_/g; # Collapse multiple underscores
        $node_label =~ s/_$//; # Remove trailing underscore
        
        # Create a sanitized URI-safe node identifier
        my $property_node_uri = $subject_uri . '_' . $tag . '_' . $node_label;
        
        # Link subject to the property node
        push @triples, {
            subject     => $subject_uri,
            predicate   => $property,
            object      => $property_node_uri,
            object_type => 'uri',
        };
        
        # Add type declaration if specified
        if ($object_type) {
            push @triples, {
                subject     => $property_node_uri,
                predicate   => 'rdf:type',
                object      => $object_type,
                object_type => 'uri',
            };
        }
        
        # Process subfields according to mapping
        foreach my $subfield ($field->subfields()) {
            my ($code, $value) = @$subfield;
            next unless $value;
            
            my $subproperty = $subproperties->{$code};
            next unless $subproperty;
            
            # Determine if this should be a resource or literal
            my $is_uri = 0;
            
            # Check if the subproperty indicates a URI relationship
            if ($subproperty =~ /^bffi:(place|agent|subject|work|expression|manifestation|item)$/) {
                $is_uri = 1;
            }
            # Role should be URI (to vocabulary like http://id.loc.gov/vocabulary/relators/XXX)
            elsif ($subproperty =~ /^bffi:role$/ || $subproperty =~ /^bf:role$/) {
                $is_uri = 1;
            }
            # Source (subfield 2) should be URI (to vocabulary/scheme)
            elsif ($subproperty =~ /^bffi:source$/ || $subproperty =~ /^bf:source$/ || $code eq '2') {
                $is_uri = 1;
            }
            # Check for other RDA/BF properties that indicate relationships
            elsif ($subproperty =~ /^(rdaw|rdae|rdam|rdai|bf):(agent|creator|contributor|publisher|manufacturer)/) {
                $is_uri = 1;
            }
            
            # Attach subproperties to the property node, not the main subject
            push @triples, {
                subject     => $property_node_uri,
                predicate   => $subproperty,
                object      => $value,
                object_type => $is_uri ? 'uri' : 'literal',
            };
        }
    }
    
    return \@triples;
}

# Enhanced agent mapping using Mapping configuration
sub _map_agents_with_mapping {
    my ($self, $marc_record, $work_uri, $base_uri) = @_;
    my @triples;
    
    foreach my $field ($marc_record->fields()) {
        my $tag = $field->tag();
        next unless exists $AGENT_FIELDS{$tag};
        
        # Get mapping for this agent field
        my $mapping = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_work_mapping($tag) ||
                     Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_expression_mapping($tag);
        
        next unless $mapping;
        
        # Build agent name from subfields
        my $agent_name = '';
        my %agent_data;
        
        foreach my $subfield ($field->subfields()) {
            my ($code, $value) = @$subfield;
            next unless $value;
            
            $agent_data{$code} = $value;
            
            # Build name from main subfields
            if ($code eq 'a' || ($code eq 'b' && $tag =~ /^1[01]0$/)) {
                $agent_name .= $value . ' ';
            }
        }
        
        $agent_name =~ s/\s+$//;
        next unless $agent_name;
        
        # Generate agent URI
        my $agent_uri = "${base_uri}agent/" . $agent_name;
        $agent_uri =~ s/[\s,\.]+/_/g;
        $agent_uri =~ s/_$//; # Remove trailing underscore
        
        # Determine agent type from mapping or tag
        my $agent_type = $mapping->{type} || 
                        (($tag eq '110' || $tag eq '710') ? 'bffi:Organization' :
                         ($tag eq '111' || $tag eq '711') ? 'bffi:Meeting' : 'bffi:Person');
        
        # Add contribution/creator relationship
        my $relationship_property = $mapping->{property} || 'bffi:contribution';
        
        push @triples, {
            subject     => $work_uri,
            predicate   => $relationship_property,
            object      => $agent_uri,
            object_type => 'uri',
        };
        
        # Add agent label
        push @triples, {
            subject     => $agent_uri,
            predicate   => 'rdfs:label',
            object      => $agent_name,
            object_type => 'literal',
        };
        
        # Add agent type
        push @triples, {
            subject     => $agent_uri,
            predicate   => 'rdf:type',
            object      => Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping::get_class_uri($agent_type) || $agent_type,
            object_type => 'uri',
        };
        
        # Add additional agent properties from subfield mapping
        if (my $subproperties = $mapping->{subproperties}) {
            foreach my $code (keys %agent_data) {
                next if $code eq 'a'; # Already used for label
                my $subproperty = $subproperties->{$code};
                next unless $subproperty;
                
                push @triples, {
                    subject     => $agent_uri,
                    predicate   => $subproperty,
                    object      => $agent_data{$code},
                    object_type => 'literal',
                };
            }
        }
    }
    
    return \@triples;
}

sub convert_record_with_xslt {
    my ($self, $marc_record, %options) = @_;

    my $base_uri    = $options{base_uri}    || 'http://example.org/';
    my $idsource    = $options{idsource}    || '';
    my $idfield     = $options{idfield}     || '001';
    my $localfields = $options{localfields} ? 'true()' : 'false()';

    my $parser   = XML::LibXML->new();
    my $xslt     = XML::LibXSLT->new();
    my $xslt_path = $options{xslt_path} || $self->_find_xslt_path();

    my $stylesheet = $xslt->parse_stylesheet_file($xslt_path);
    my $source     = $parser->parse_string( $marc_record->as_xml() );

    my $results = $stylesheet->transform(
        $source,
        baseuri     => "'" . $base_uri . "'",
        idfield     => "'" . $idfield . "'",
        idsource    => "'" . $idsource . "'",
        localfields => $localfields,
    );

    return $stylesheet->output_as_bytes($results);
}

sub _find_xslt_path {
    my ($self) = @_;
    my $module_dir = dirname(__FILE__);
    return "$module_dir/../config/marc2bibframe2.xsl";
}

1;