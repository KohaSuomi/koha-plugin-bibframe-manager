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
        # Simple JSON representation
        return JSON->new->utf8->pretty->encode($triples);
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
    
    # Default to JSON
    return JSON->new->utf8->pretty->encode($triples);
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
