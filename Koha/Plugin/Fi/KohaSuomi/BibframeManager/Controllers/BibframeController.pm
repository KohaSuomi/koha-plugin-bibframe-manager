package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Controllers::BibframeController;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use Koha::Biblios;
use MARC::Record;
use MARC::File::USMARC;
use MARC::File::XML;
use MIME::Base64;
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
        # Get parameters from JSON body
        my $body = $c->validation->output;
        my $biblionumber = $body->{biblionumber};
        my $triples = $body->{triples};
        my $format = $body->{format} || 'turtle';
        my $schema = $body->{schema} || 'Bibframe';

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
        # Get parameters from JSON body
        my $body = $c->req->json;
        my $method = $body->{method} || 'biblio';
        my $base_uri = $body->{base_uri} || 'http://urn.fi/URN:NBN:fi:bib:';
        my $format = $body->{format} || 'turtle';
        my $save_to_db = $body->{save_to_db} || 0;
        
        my $marc_record;
        my $biblionumber;

        # Get MARC record based on input method
        if ($method eq 'biblio') {
            $biblionumber = $body->{biblionumber};
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
            # Handle base64 encoded MARC file from JSON body
            my $marc_file_b64 = $body->{marc_file};
            unless ($marc_file_b64) {
                return $c->render(
                    status => 400,
                    openapi => { error => 'MARC file (base64 encoded) is required' }
                );
            }

            # Decode base64
            require MIME::Base64;
            my $marc_data = MIME::Base64::decode_base64($marc_file_b64);
            $marc_record = eval { MARC::Record->new_from_usmarc($marc_data) };
            
            if ($@) {
                return $c->render(
                    status => 400,
                    openapi => { error => "Invalid MARC file: $@" }
                );
            }
            
        } elsif ($method eq 'text') {
            my $marc_text = $body->{marc_text};
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

        # Determine conversion standard
        my $standard = $body->{standard} || 'bffi';

        # Convert to Bibframe
        my $converter = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe->new();

        if ($standard eq 'loc') {
            # Use LoC XSLT-based conversion
            my $loc_format = $format eq 'json' ? 'json' : 'rdf-xml';
            my $xslt_path = $body->{xslt_path} || undef;

            my %xslt_opts = (
                base_uri => $base_uri,
            );
            $xslt_opts{xslt_path} = $xslt_path if $xslt_path;

            my $rdfxml = $converter->convert_record_with_xslt($marc_record, %xslt_opts);

            unless ($rdfxml) {
                return $c->render(
                    status => 500,
                    openapi => { error => 'XSLT conversion produced no output' }
                );
            }

            # Convert to JSON if requested
            my $formatted_output;
            if ($format eq 'json') {
                $formatted_output = $converter->rdf_to_json($rdfxml);
            } else {
                $formatted_output = $rdfxml;
            }

            # Save to database if requested
            my $metadata_id = 0;
            if ($save_to_db && $biblionumber) {
                my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
                $metadata_id = $db->saveBibframeMetadata(
                    $biblionumber,
                    [],
                    format => $loc_format,
                    schema => 'BIBFRAME'
                );
            }

            return $c->render(
                status => 200,
                openapi => {
                    formatted => $formatted_output,
                    format => $loc_format,
                    standard => 'loc',
                    biblionumber => $biblionumber,
                    metadata_id => $metadata_id,
                    message => 'MARC21 record successfully converted to BIBFRAME via LoC XSLT'
                }
            );
        }

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
        my $db = Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database->new();
        my $formatted_output = $db->serializeTriples($triples, $format);

        # Save to database if requested
        my $metadata_id = 0;
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
                triples => $triples,
                formatted => $formatted_output,
                format => $format,
                standard => $standard,
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
