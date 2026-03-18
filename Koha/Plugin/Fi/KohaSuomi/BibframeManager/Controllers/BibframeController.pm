package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Controllers::BibframeController;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use Koha::Biblios;
use MARC::Record;
use MARC::File::USMARC;
use MARC::File::XML;
use Try::Tiny;
use JSON;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Controllers::BibframeController

=head1 DESCRIPTION

Controller for Bibframe conversion API endpoints

=head1 API METHODS

=head2 add
POST /api/v1/contrib/kohasuomi/bibframe

Adds a new Bibframe metadata record to the database

=cut

sub add {
    my $c = shift->openapi->valid_input or return;

    return try {
        
        my $triples = $c->param('triples');
        my $format = $c->param('format') || 'turtle';
        my $schema = $c->param('schema') || 'Bibframe';

        unless ($biblionumber && $triples) {
            return $c->render(
                status => 400,
                openapi => { error => 'biblionumber and triples are required' }
            );
        }

        my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
        my $metadata_id = $db->saveBibframeMetadata(
            $biblionumber,
            $triples,
            format => $format,
            schema => $schema
        );

        return $c->render(
            status => 201,
            openapi => {
                success => JSON::true,
                metadata_id => $metadata_id,
                message => 'Bibframe metadata record successfully added to database'
            }
        );

    } catch {
        warn "Error adding Bibframe metadata: $_";
        return $c->render(
            status => 500,
            openapi => { error => "Internal server error: $_" }
        );
    };
}

=head2 convert

POST /api/v1/contrib/kohasuomi/bibframe/convert

Converts a MARC21 record to Bibframe format

=cut

sub convert {
    my $c = shift->openapi->valid_input or return;

    return try {
        my $method = $c->param('method') || 'biblio';
        my $base_uri = $c->param('base_uri') || 'http://urn.fi/URN:NBN:fi:bib:';
        my $format = $c->param('format') || 'turtle';
        my $save_to_db = $c->param('save_to_db') || 0;
        
        my $marc_record;
        my $biblionumber;

        # Get MARC record based on input method
        if ($method eq 'biblio') {
            $biblionumber = $c->param('biblionumber');
            unless ($biblionumber) {
                return $c->render(
                    status => 400,
                    openapi => { error => 'Biblionumber is required' }
                );
            }

            my $biblio = Koha::Biblios->find($biblionumber);
            unless ($biblio) {
                return $c->render(
                    status => 404,
                    openapi => { error => "No record found for biblionumber $biblionumber" }
                );
            }

            $marc_record = $biblio->metadata->record;
            
        } elsif ($method eq 'marc') {
            # Handle file upload
            my $upload = $c->req->upload('marc_file');
            unless ($upload) {
                return $c->render(
                    status => 400,
                    openapi => { error => 'MARC file is required' }
                );
            }

            my $marc_data = $upload->slurp;
            $marc_record = eval { MARC::Record->new_from_usmarc($marc_data) };
            
            if ($@) {
                return $c->render(
                    status => 400,
                    openapi => { error => "Invalid MARC file: $@" }
                );
            }
            
        } elsif ($method eq 'text') {
            my $marc_text = $c->param('marc_text');
            unless ($marc_text) {
                return $c->render(
                    status => 400,
                    openapi => { error => 'MARC text is required' }
                );
            }

            # Try to parse MARC text (could be MARCXML or other format)
            $marc_record = eval { MARC::Record->new_from_xml($marc_text) };
            
            if ($@) {
                return $c->render(
                    status => 400,
                    openapi => { error => "Invalid MARC text: $@" }
                );
            }
        } else {
            return $c->render(
                status => 400,
                openapi => { error => "Invalid method: $method" }
            );
        }

        unless ($marc_record) {
            return $c->render(
                status => 400,
                openapi => { error => 'Failed to load MARC record' }
            );
        }

        # Convert to Bibframe
        my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();
        
        my $full_base_uri = $base_uri;
        $full_base_uri .= $biblionumber if $biblionumber;
        
        my $triples = $converter->convert_record_to_Bibframe(
            $marc_record,
            base_uri => $full_base_uri
        );

        unless ($triples && @$triples) {
            return $c->render(
                status => 500,
                openapi => { error => 'Conversion produced no triples' }
            );
        }

        # Format the output
        my $formatted_output;
        my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
        
        if ($format eq 'turtle') {
            $formatted_output = $db->formatAsTurtle($triples);
        } elsif ($format eq 'json-ld') {
            $formatted_output = $db->formatAsJsonLd($triples);
        } elsif ($format eq 'ntriples') {
            $formatted_output = $db->formatAsNTriples($triples);
        } elsif ($format eq 'rdf-xml') {
            $formatted_output = $db->formatAsRdfXml($triples);
        } else {
            $formatted_output = $db->formatAsTurtle($triples);
        }

        # Save to database if requested
        my $metadata_id;
        if ($save_to_db && $biblionumber) {
            $metadata_id = $db->saveBibframeMetadata(
                $biblionumber,
                $triples,
                format => $format,
                schema => 'Bibframe'
            );
        }

        # Return response
        return $c->render(
            status => 200,
            openapi => {
                success => JSON::true,
                triples => $triples,
                formatted => $formatted_output,
                format => $format,
                triple_count => scalar(@$triples),
                biblionumber => $biblionumber,
                metadata_id => $metadata_id,
                message => 'MARC21 record successfully converted to Bibframe'
            }
        );

    } catch {
        warn "Bibframe conversion error: $_";
        return $c->render(
            status => 500,
            openapi => { error => "Internal server error: $_" }
        );
    };
}

1;
