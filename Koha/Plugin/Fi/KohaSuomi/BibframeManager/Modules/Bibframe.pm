package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;

use strict;
use warnings;
use Try::Tiny;
use MARC::Record;
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
    
    # Get the appropriate mapping based on level
    my $mapping_func = "get_${level}_mapping";
    
    foreach my $field ($marc_record->fields()) {
        my $tag = $field->tag();
        next unless exists $field_hash->{$tag};
        
        my $mapping = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping->can($mapping_func)
            ? Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Mapping->$mapping_func($tag)
            : undef;
        
        next unless $mapping;
        
        # Handle the main property
        my $property = $mapping->{property};
        my $object_type = $mapping->{type};
        my $subproperties = $mapping->{subproperties} || {};
        
        # Process subfields according to mapping
        foreach my $subfield ($field->subfields()) {
            my ($code, $value) = @$subfield;
            next unless $value;
            
            my $subproperty = $subproperties->{$code};
            next unless $subproperty;
            
            # Determine if this should be a resource or literal
            my $is_uri = ($subproperty =~ /^bffi:(place|agent|subject|work|expression|manifestation|item)/ ||
                         $code eq '2' || $code eq 'e'); # Source and role are often URIs
            
            push @triples, {
                subject     => $subject_uri,
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

1;