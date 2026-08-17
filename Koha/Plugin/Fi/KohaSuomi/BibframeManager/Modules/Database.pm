package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;

# Copyright 2025 Koha-Suomi Oy
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use Carp;
use Scalar::Util qw( blessed );
use Try::Tiny;
use JSON;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager;
use C4::Context;

=head new

    my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new($params);

=cut

sub new {
    my ($class, $params) = @_;
    my $self = {};
    $self->{_params} = $params;
    bless($self, $class);
    return $self;

}

sub plugin {
    my ($self) = @_;
    return Koha::Plugin::Fi::KohaSuomi::BibframeManager->new;
}

sub dbh {
    my ($self) = @_;
    return C4::Context->dbh;
}

=head2 saveBibframeMetadata

    $db->saveBibframeMetadata($biblionumber, $triples, %options);
    
    Saves Bibframe/BIBFRAME metadata to biblio_metadata table.
    
    Parameters:
      $biblionumber - The biblionumber to attach metadata to
      $triples      - Arrayref of RDF triples
      %options      - Optional parameters:
                      format => 'turtle' (default), 'rdfxml', 'json-ld', 'ntriples'
                      schema => 'Bibframe' (default), 'BIBFRAME'
                      
    Returns: The metadata id
=cut

sub saveBibframeMetadata {
    my ($self, $biblionumber, $triples, %options) = @_;
    
    my $format = $options{format} || 'turtle';
    my $schema = $options{schema} || 'Bibframe';
    
    # Serialize triples to requested format
    my $metadata = $self->serializeTriples($triples, $format);
    
    # Check if metadata already exists
    my $existing = $self->getBibframeMetadata($biblionumber, $format, $schema);
    
    if ($existing) {
        # Update existing metadata
        my $sth = $self->dbh->prepare(
            "UPDATE biblio_metadata 
             SET metadata = ?, timestamp = CURRENT_TIMESTAMP
             WHERE biblionumber = ? AND format = ? AND schema = ?"
        );
        $sth->execute($metadata, $biblionumber, $format, $schema);
        return $existing->{id};
    } else {
        # Insert new metadata
        my $sth = $self->dbh->prepare(
            "INSERT INTO biblio_metadata (biblionumber, format, schema, metadata)
             VALUES (?, ?, ?, ?)"
        );
        $sth->execute($biblionumber, $format, $schema, $metadata);
        return $self->dbh->last_insert_id(undef, undef, 'biblio_metadata', 'id');
    }
}

=head2 getBibframeMetadata

    my $metadata = $db->getBibframeMetadata($biblionumber, $format, $schema);
    
    Retrieves Bibframe/BIBFRAME metadata from biblio_metadata table.
    
    Parameters:
      $biblionumber - The biblionumber
      $format       - Optional: 'turtle', 'rdfxml', 'json-ld', 'ntriples' (default: 'turtle')
      $schema       - Optional: 'Bibframe', 'BIBFRAME' (default: 'Bibframe')
      
    Returns: Hashref with metadata fields or undef if not found
=cut

sub getBibframeMetadata {
    my ($self, $biblionumber, $format, $schema) = @_;
    
    $format ||= 'turtle';
    $schema ||= 'Bibframe';
    
    my $sth = $self->dbh->prepare(
        "SELECT * FROM biblio_metadata 
         WHERE biblionumber = ? AND format = ? AND schema = ?"
    );
    $sth->execute($biblionumber, $format, $schema);
    return $sth->fetchrow_hashref();
}

=head2 getAllBibframeMetadata

    my $metadata_list = $db->getAllBibframeMetadata($biblionumber);
    
    Retrieves all Bibframe/BIBFRAME metadata for a biblionumber (all formats/schemas).
    
    Parameters:
      $biblionumber - The biblionumber
      
    Returns: Arrayref of metadata records
=cut

sub getAllBibframeMetadata {
    my ($self, $biblionumber) = @_;
    
    my $sth = $self->dbh->prepare(
        "SELECT * FROM biblio_metadata 
         WHERE biblionumber = ? AND schema IN ('Bibframe', 'BIBFRAME')
         ORDER BY schema, format"
    );
    $sth->execute($biblionumber);
    return $sth->fetchall_arrayref({});
}

=head2 deleteBibframeMetadata

    $db->deleteBibframeMetadata($biblionumber, $format, $schema);
    
    Deletes Bibframe/BIBFRAME metadata for a biblionumber.
    
    Parameters:
      $biblionumber - The biblionumber
      $format       - Optional: specific format to delete (default: delete all formats)
      $schema       - Optional: specific schema to delete (default: delete all Bibframe/BIBFRAME)
=cut

sub deleteBibframeMetadata {
    my ($self, $biblionumber, $format, $schema) = @_;
    
    my $sql = "DELETE FROM biblio_metadata WHERE biblionumber = ?";
    my @params = ($biblionumber);
    
    if ($format && $schema) {
        $sql .= " AND format = ? AND schema = ?";
        push @params, $format, $schema;
    } elsif ($schema) {
        $sql .= " AND schema = ?";
        push @params, $schema;
    } else {
        # Delete all Bibframe/BIBFRAME variants
        $sql .= " AND schema IN ('Bibframe', 'BIBFRAME')";
    }
    
    my $sth = $self->dbh->prepare($sql);
    $sth->execute(@params);
}

=head2 serializeTriples

    my $serialized = $db->serializeTriples($triples, $format);
    
    Serializes RDF triples to specified format.
    
    Parameters:
      $triples - Arrayref of triple hashrefs with subject, predicate, object, object_type
      $format  - 'turtle', 'rdfxml', 'json-ld', 'ntriples'
      
    Returns: Serialized string
=cut

sub serializeTriples {
    my ($self, $triples, $format) = @_;
    
    $format ||= 'turtle';
    
    if ($format eq 'json') {
        return $self->_toJson($triples);
    } elsif ($format eq 'ntriples') {
        # N-Triples format
        return $self->_toNTriples($triples);
    } elsif ($format eq 'turtle') {
        # Turtle format
        return $self->_toTurtle($triples);
    } elsif ($format eq 'rdfxml') {
        # RDF/XML format
        return $self->_toRdfXml($triples);
    } elsif ($format eq 'json-ld') {
        # JSON-LD format
        return $self->_toJsonLd($triples);
    }
    
    # Default to structured JSON
    return $self->_toJson($triples);
}

=head2 _toNTriples

    Internal method to serialize triples to N-Triples format
=cut

sub _toNTriples {
    my ($self, $triples) = @_;
    
    my $output = '';
    foreach my $triple (@$triples) {
        my $subject = '<' . $triple->{subject} . '>';
        my $predicate = '<' . $triple->{predicate} . '>';
        my $object;
        
        if ($triple->{object_type} eq 'uri') {
            $object = '<' . $triple->{object} . '>';
        } else {
            # Literal
            my $value = $triple->{object};
            $value =~ s/\\/\\\\/g;
            $value =~ s/"/\\"/g;
            $value =~ s/\n/\\n/g;
            $value =~ s/\r/\\r/g;
            $value =~ s/\t/\\t/g;
            $object = '"' . $value . '"';
            
            if ($triple->{datatype}) {
                $object .= '^^<' . $triple->{datatype} . '>';
            } elsif ($triple->{lang}) {
                $object .= '@' . $triple->{lang};
            }
        }
        
        $output .= "$subject $predicate $object .\n";
    }
    
    return $output;
}

=head2 _toTurtle

    Internal method to serialize triples to Turtle format
=cut

sub _toTurtle {
    my ($self, $triples) = @_;
    
    # Turtle with common prefixes
    my $output = <<'PREFIXES';
@prefix bf: <http://id.loc.gov/ontologies/bibframe/> .
@prefix Bibframe: <http://urn.fi/URN:NBN:fi:schema:Bibframe:> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdaw: <http://rdaregistry.info/Elements/w/> .
@prefix rdae: <http://rdaregistry.info/Elements/e/> .
@prefix rdam: <http://rdaregistry.info/Elements/m/> .
@prefix rdai: <http://rdaregistry.info/Elements/i/> .

PREFIXES

    # Group by subject
    my %by_subject;
    foreach my $triple (@$triples) {
        push @{$by_subject{$triple->{subject}}}, $triple;
    }
    
    foreach my $subject (sort keys %by_subject) {
        $output .= "<$subject>\n";
        my @statements = @{$by_subject{$subject}};
        
        for (my $i = 0; $i < @statements; $i++) {
            my $triple = $statements[$i];
            my $predicate = $triple->{predicate};
            my $object;
            
            if ($triple->{object_type} eq 'uri') {
                $object = '<' . $triple->{object} . '>';
            } else {
                my $value = $triple->{object};
                $value =~ s/\\/\\\\/g;
                $value =~ s/"/\\"/g;
                $object = '"' . $value . '"';
                
                if ($triple->{datatype}) {
                    $object .= '^^<' . $triple->{datatype} . '>';
                } elsif ($triple->{lang}) {
                    $object .= '@' . $triple->{lang};
                }
            }
            
            my $separator = ($i == $#statements) ? " .\n" : " ;\n";
            $output .= "    <$predicate> $object$separator";
        }
        $output .= "\n";
    }
    
    return $output;
}

=head2 _toRdfXml

    Internal method to serialize triples to RDF/XML format
=cut

sub _toRdfXml {
    my ($self, $triples) = @_;
    
    my $output = <<'XML_HEADER';
<?xml version="1.0" encoding="UTF-8"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns:bf="http://id.loc.gov/ontologies/bibframe/"
         xmlns:Bibframe="http://urn.fi/URN:NBN:fi:schema:Bibframe:"
         xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#"
         xmlns:rdaw="http://rdaregistry.info/Elements/w/"
         xmlns:rdae="http://rdaregistry.info/Elements/e/"
         xmlns:rdam="http://rdaregistry.info/Elements/m/">

XML_HEADER

    # Group by subject
    my %by_subject;
    foreach my $triple (@$triples) {
        push @{$by_subject{$triple->{subject}}}, $triple;
    }
    
    foreach my $subject (sort keys %by_subject) {
        $output .= qq{  <rdf:Description rdf:about="$subject">\n};
        
        foreach my $triple (@{$by_subject{$subject}}) {
            my $pred_uri = $triple->{predicate};
            my ($ns, $localname) = $pred_uri =~ m{^(.+[/#])([^/#]+)$};
            
            if ($triple->{object_type} eq 'uri') {
                $output .= qq{    <property rdf:resource="$triple->{object}" xmlns:property="$pred_uri"/>\n};
            } else {
                my $value = $triple->{object};
                $value =~ s/&/&amp;/g;
                $value =~ s/</&lt;/g;
                $value =~ s/>/&gt;/g;
                $value =~ s/"/&quot;/g;
                
                my $attrs = '';
                if ($triple->{lang}) {
                    $attrs = qq{ xml:lang="$triple->{lang}"};
                } elsif ($triple->{datatype}) {
                    $attrs = qq{ rdf:datatype="$triple->{datatype}"};
                }
                
                $output .= qq{    <property xmlns:property="$ns"$attrs>$value</property>\n};
            }
        }
        
        $output .= qq{  </rdf:Description>\n};
    }
    
    $output .= "</rdf:RDF>\n";
    return $output;
}

=head2 _toJson

    Internal method to serialize triples to structured BIBFRAME JSON.
    Groups triples by entity type and builds a hierarchical representation.

=cut

# Namespace prefix mapping for readable predicate names
my %NAMESPACE_PREFIX = (
    'http://id.loc.gov/ontologies/bibframe/'        => 'bf',
    'http://urn.fi/URN:NBN:fi:schema:bffi:'          => 'bffi',
    'http://urn.fi/URN:NBN:fi:schema:Bibframe:'      => 'Bibframe',
    'http://www.w3.org/2000/01/rdf-schema#'          => 'rdfs',
    'http://www.w3.org/1999/02/22-rdf-syntax-ns#'    => 'rdf',
    'http://rdaregistry.info/Elements/w/'             => 'rdaw',
    'http://rdaregistry.info/Elements/e/'             => 'rdae',
    'http://rdaregistry.info/Elements/m/'             => 'rdam',
    'http://rdaregistry.info/Elements/i/'             => 'rdai',
    'http://id.loc.gov/ontologies/bflc/'             => 'bflc',
    'http://purl.org/dc/elements/1.1/'                => 'dc',
    'http://purl.org/dc/terms/'                       => 'dcterms',
);

# Predicate local names that map to meaningful JSON keys
my %PREDICATE_KEY = (
    'title'              => 'title',
    'mainTitle'          => 'mainTitle',
    'subtitle'           => 'subtitle',
    'language'           => 'language',
    'subject'            => 'subjects',
    'contribution'       => 'contributors',
    'creator'            => 'creators',
    'contributor'        => 'contributors',
    'agent'              => 'agents',
    'instanceOf'         => 'instanceOf',
    'hasInstance'        => 'instances',
    'hasWork'            => 'works',
    'content'            => 'content',
    'classification'     => 'classifications',
    'subject'            => 'subjects',
    'note'               => 'notes',
    'identifier'         => 'identifiers',
    'identifiedBy'       => 'identifiers',
    'provisionActivity'  => 'provisionActivity',
    'publicationStatement' => 'publicationStatement',
    'extent'             => 'extent',
    'carrierType'        => 'carrierType',
    'mediaType'          => 'mediaType',
    'electronicLocator'  => 'electronicLocator',
    'series'             => 'series',
    'hasExpression'      => 'hasExpression',
    'expressionOf'       => 'expressionOf',
    'manifestationOfExpression' => 'manifestationOfExpression',
    'expressionManifested' => 'expressionManifested',
    'role'               => 'role',
    'source'             => 'source',
    'code'               => 'code',
    'date'               => 'date',
    'status'             => 'status',
    'assigner'           => 'assigner',
    'illustrativeContent' => 'illustrativeContent',
    'supplementaryContent' => 'supplementaryContent',
    'cartographicAttributes' => 'cartographicAttributes',
    'form'               => 'form',
    'genreForm'          => 'genreForm',
    'adminMetadata'      => 'adminMetadata',
    'descriptionLevel'   => 'descriptionLevel',
    'encodingLevel'      => 'encodingLevel',
);

sub _toJson {
    my ($self, $triples) = @_;

    return '{}' unless $triples && @$triples;

    # Group triples by subject
    my %by_subject;
    foreach my $triple (@$triples) {
        push @{$by_subject{$triple->{subject}}}, $triple;
    }

    # Identify entity types from rdf:type triples
    my %entity_types;  # subject -> [types]
    my %type_uris = (
        'http://id.loc.gov/ontologies/bibframe/Work'         => 'Work',
        'http://id.loc.gov/ontologies/bibframe/Instance'     => 'Instance',
        'http://id.loc.gov/ontologies/bibframe/Expression'   => 'Expression',
        'http://id.loc.gov/ontologies/bibframe/Item'         => 'Item',
        'http://id.loc.gov/ontologies/bibframe/Agent'        => 'Agent',
        'http://id.loc.gov/ontologies/bibframe/Person'       => 'Person',
        'http://id.loc.gov/ontologies/bibframe/Organization' => 'Organization',
        'http://id.loc.gov/ontologies/bibframe/Meeting'      => 'Meeting',
        'http://id.loc.gov/ontologies/bibframe/Topic'        => 'Topic',
        'http://id.loc.gov/ontologies/bibframe/Language'     => 'Language',
        'http://id.loc.gov/ontologies/bibframe/Title'        => 'Title',
        'http://id.loc.gov/ontologies/bibframe/Contribution' => 'Contribution',
        'http://id.loc.gov/ontologies/bibframe/ClassificationLcc' => 'ClassificationLcc',
        'http://id.loc.gov/ontologies/bibframe/ClassificationDdc' => 'ClassificationDdc',
        'http://id.loc.gov/ontologies/bibframe/Content'      => 'Content',
        'http://id.loc.gov/ontologies/bibframe/Status'       => 'Status',
        'http://id.loc.gov/ontologies/bibframe/Source'       => 'Source',
        'http://id.loc.gov/ontologies/bibframe/AdminMetadata' => 'AdminMetadata',
        'http://id.loc.gov/ontologies/bibframe/Illustration' => 'Illustration',
        'http://id.loc.gov/ontologies/bibframe/SupplementaryContent' => 'SupplementaryContent',
    );

    foreach my $subject (keys %by_subject) {
        $entity_types{$subject} = [];
        foreach my $t (@{$by_subject{$subject}}) {
            if ($t->{predicate} =~ /rdf:type$/ && $t->{object_type} eq 'uri') {
                my $short = $type_uris{$t->{object}};
                push @{$entity_types{$subject}}, $short || $t->{object};
            }
        }
    }

    # Classify subjects into BIBFRAME entity categories
    my ($work_uri, $expression_uri, $manifestation_uri, $item_uri);
    my @agent_uris;
    my @subject_uris;

    foreach my $subject (keys %entity_types) {
        my @types = @{$entity_types{$subject}};
        if (grep { $_ eq 'Work' } @types) {
            $work_uri = $subject;
        } elsif (grep { $_ eq 'Expression' } @types) {
            $expression_uri = $subject;
        } elsif (grep { $_ eq 'Instance' } @types) {
            $manifestation_uri = $subject;
        } elsif (grep { $_ eq 'Item' } @types) {
            $item_uri = $subject;
        } elsif (grep { /^(Agent|Person|Organization|Meeting)$/ } @types) {
            push @agent_uris, $subject;
        } elsif (grep { $_ eq 'Topic' } @types) {
            push @subject_uris, $subject;
        }
    }

    # If no typed entities found, try to infer from URI patterns
    unless ($work_uri) {
        for my $uri (keys %by_subject) {
            if ($uri =~ m{/works?/}) {
                $work_uri = $uri;
                last;
            }
        }
    }
    unless ($manifestation_uri) {
        for my $uri (keys %by_subject) {
            if ($uri =~ m{/instances?/}) {
                $manifestation_uri = $uri;
                last;
            }
        }
    }

    # Build the result
    my $result = {};

    if ($work_uri) {
        $result->{work} = $self->_build_entity_json($work_uri, \%by_subject, \%entity_types);
    }

    if ($expression_uri) {
        $result->{expression} = $self->_build_entity_json($expression_uri, \%by_subject, \%entity_types);
    }

    if ($manifestation_uri) {
        $result->{manifestation} = $self->_build_entity_json($manifestation_uri, \%by_subject, \%entity_types);
    }

    if ($item_uri) {
        $result->{item} = $self->_build_entity_json($item_uri, \%by_subject, \%entity_types);
    }

    if (@agent_uris) {
        $result->{agents} = [
            map { $self->_build_entity_json($_, \%by_subject, \%entity_types) } @agent_uris
        ];
    }

    if (@subject_uris) {
        $result->{subjects} = [
            map { $self->_build_entity_json($_, \%by_subject, \%entity_types) } @subject_uris
        ];
    }

    # If no structured entities found, return all subjects as a flat graph
    unless ($result->{work} || $result->{expression} || $result->{manifestation}) {
        my @all_entities;
        for my $uri (sort keys %by_subject) {
            push @all_entities, $self->_build_entity_json($uri, \%by_subject, \%entity_types);
        }
        $result->{entities} = \@all_entities;
    }

    return JSON->new->utf8->pretty->encode($result);
}

=head2 _build_entity_json

    Builds a structured JSON hash for a single RDF entity (subject).

=cut

sub _build_entity_json {
    my ($self, $subject_uri, $by_subject, $entity_types) = @_;

    my $entity = {
        uri => $subject_uri,
    };

    # Add types
    if ($entity_types->{$subject_uri} && @{$entity_types->{$subject_uri}}) {
        $entity->{types} = $entity_types->{$subject_uri};
    }

    my $triples = $by_subject->{$subject_uri} || [];

    foreach my $t (@$triples) {
        my $pred = $t->{predicate};
        next if $pred =~ /rdf:type$/; # Already handled

        # Extract local name from predicate URI
        my ($localname) = $pred =~ m{[/#]([^/#]+)$};
        next unless $localname;

        # Determine the JSON key
        my $key = $PREDICATE_KEY{$localname} || $localname;

        # For URI objects, build a reference
        my $value;
        if ($t->{object_type} eq 'uri') {
            $value = { uri => $t->{object} };
        } else {
            $value = $t->{object};
            if ($t->{lang}) {
                $value = { value => $t->{object}, language => $t->{lang} };
            } elsif ($t->{datatype}) {
                $value = { value => $t->{object}, datatype => $t->{datatype} };
            }
        }

        # Handle nested entities: if the object is itself a subject with triples,
        # build a nested entity representation
        if ($t->{object_type} eq 'uri' && $by_subject->{$t->{object}}) {
            my $nested = $self->_build_entity_json($t->{object}, $by_subject, $entity_types);
            $value = $nested;
        }

        # Add to entity, handling arrays
        if (exists $entity->{$key}) {
            if (ref $entity->{$key} eq 'ARRAY') {
                push @{$entity->{$key}}, $value;
            } else {
                $entity->{$key} = [$entity->{$key}, $value];
            }
        } else {
            $entity->{$key} = $value;
        }
    }

    return $entity;
}

=head2 _toJsonLd

    Internal method to serialize triples to JSON-LD format
=cut

sub _toJsonLd {
    my ($self, $triples) = @_;
    
    my $context = {
        "bf" => "http://id.loc.gov/ontologies/bibframe/",
        "Bibframe" => "http://urn.fi/URN:NBN:fi:schema:Bibframe:",
        "rdfs" => "http://www.w3.org/2000/01/rdf-schema#",
        "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
        "rdaw" => "http://rdaregistry.info/Elements/w/",
        "rdae" => "http://rdaregistry.info/Elements/e/",
        "rdam" => "http://rdaregistry.info/Elements/m/",
    };
    
    # Group by subject
    my %by_subject;
    foreach my $triple (@$triples) {
        push @{$by_subject{$triple->{subject}}}, $triple;
    }
    
    my @graph;
    foreach my $subject (sort keys %by_subject) {
        my $node = {
            '@id' => $subject
        };
        
        foreach my $triple (@{$by_subject{$subject}}) {
            my $pred = $triple->{predicate};
            my $value;
            
            if ($triple->{object_type} eq 'uri') {
                $value = { '@id' => $triple->{object} };
            } else {
                $value = { '@value' => $triple->{object} };
                if ($triple->{lang}) {
                    $value->{'@language'} = $triple->{lang};
                } elsif ($triple->{datatype}) {
                    $value->{'@type'} = $triple->{datatype};
                }
            }
            
            # Add to node
            if (exists $node->{$pred}) {
                if (ref $node->{$pred} eq 'ARRAY') {
                    push @{$node->{$pred}}, $value;
                } else {
                    $node->{$pred} = [$node->{$pred}, $value];
                }
            } else {
                $node->{$pred} = $value;
            }
        }
        
        push @graph, $node;
    }
    
    my $jsonld = {
        '@context' => $context,
        '@graph' => \@graph
    };
    
    return JSON->new->utf8->pretty->encode($jsonld);
}

=head2 Legacy methods (for backward compatibility)

=cut

sub insertBibframeManager {
    my ($self, $subject, $predicate, $object, $object_type, $datatype, $lang) = @_;
    warn "insertBibframeManager is deprecated. Use saveBibframeMetadata instead.";
    # This would need biblionumber extraction from subject URI
}

sub getBibframeManagers {
    my ($self, $subject) = @_;
    warn "getBibframeManagers is deprecated. Use getBibframeMetadata instead.";
    return [];
}

sub deleteBibframeManagersBySubject {
    my ($self, $subject) = @_;
    warn "deleteBibframeManagersBySubject is deprecated. Use deleteBibframeMetadata instead.";
}


1;
