package Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::MarcGenerator;

use strict;
use warnings;
use utf8;
use Try::Tiny;
use JSON;
use MARC::Record;
use C4::Context;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::MarcGenerator

=head1 DESCRIPTION

Phase 10: Reconstructs MARC21 records from the storage layer.

The canonical semantic (EAV) store keeps BIBFRAME property URIs, not original
MARC subfields, so exact MARC reconstruction from the EAV is lossy. MarcGenerator
therefore returns the authoritative saved MARC copy:

  1. record_format_mappings.format_name='marc21' (serialized_data) - the
     per-resource saved copy written by the semantic store.
  2. Koha biblio_metadata (format='marcxml') - the Koha authoritative copy,
     keyed by biblio_id.

This gives the generator a pass-through reader of the stored MARC while the
semantic store remains the canonical linked-data source of truth.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    bless($self, $class);
    return $self;
}

sub dbh {
    return C4::Context->dbh;
}

=head1 PUBLIC METHODS

=head2 get_record

    my $record = $gen->get_record(resource_id => $id);
    my $record = $gen->get_record(biblio_id   => $biblio_id);

Resolves a resource to its authoritative MARC21 record. Looks up the saved
MARC copy in record_format_mappings first, then falls back to Koha's
biblio_metadata. Returns a MARC::Record object or undef.

=cut

sub get_record {
    my ($self, %args) = @_;

    my $resource_id = $args{resource_id};
    my $biblio_id   = $args{biblio_id};

    $biblio_id ||= $self->_biblio_id_for_resource($resource_id) if $resource_id;

    # 1. Prefer the saved MARC copy in the hybrid store
    my $record = $self->_from_format_mappings($resource_id, $biblio_id);
    return $record if $record;

    # 2. Fall back to Koha's authoritative biblio_metadata
    $record = $self->_from_biblio_metadata($biblio_id);
    return $record if $record;

    return undef;
}

=head2 get_marc_xml

    my $xml = $gen->get_marc_xml(resource_id => $id);

Returns the MARC21 record as MARC::Record XML, or undef.

=cut

sub get_marc_xml {
    my ($self, %args) = @_;

    my $record = $self->get_record(%args);
    return undef unless $record;

    return $record->as_xml();
}

=head2 get_marc_bin

    my $bin = $gen->get_marc_bin(resource_id => $id);

Returns the MARC21 record as ISO2709 MARC::File::USMARC-encoded binary, or undef.

=cut

sub get_marc_bin {
    my ($self, %args) = @_;

    my $record = $self->get_record(%args);
    return undef unless $record;

    return $record->as_usmarc();
}

=head1 PRIVATE METHODS

=cut

sub _biblio_id_for_resource {
    my ($self, $resource_id) = @_;

    return undef unless $resource_id;

    my $sth = $self->dbh->prepare(
        'SELECT biblio_id FROM record_resources WHERE id = ? LIMIT 1'
    );
    $sth->execute($resource_id);
    my $row = $sth->fetchrow_hashref();
    return $row ? $row->{biblio_id} : undef;
}

# Reads saved MARC from record_format_mappings for the resource, or any
# resource sharing the same biblio_id (the MARC copy is per-biblio).
sub _from_format_mappings {
    my ($self, $resource_id, $biblio_id) = @_;

    my $dbh = $self->dbh;

    my $rows;
    if ($biblio_id) {
        my $sth = $dbh->prepare(
            "SELECT rm.serialized_data
               FROM record_format_mappings rm
               JOIN record_resources r ON r.id = rm.resource_id
              WHERE rm.format_name = 'marc21'
                AND r.biblio_id = ?
              ORDER BY rm.updated_at DESC
              LIMIT 1"
        );
        $sth->execute($biblio_id);
        $rows = $sth->fetchall_arrayref();
    } elsif ($resource_id) {
        my $sth = $dbh->prepare(
            "SELECT serialized_data
               FROM record_format_mappings
              WHERE resource_id = ? AND format_name = 'marc21'
              LIMIT 1"
        );
        $sth->execute($resource_id);
        $rows = $sth->fetchall_arrayref();
    }

    return undef unless $rows && @$rows;

    return $self->_record_from_serialized($rows->[0]->{serialized_data});
}

# Reads Koha's authoritative MARC from biblio_metadata.
sub _from_biblio_metadata {
    my ($self, $biblio_id) = @_;

    return undef unless $biblio_id;

    my $sth = $self->dbh->prepare(
        "SELECT metadata FROM biblio_metadata
         WHERE biblionumber = ? AND format = 'marcxml'
         ORDER BY id DESC LIMIT 1"
    );
    $sth->execute($biblio_id);
    my $row = $sth->fetchrow_hashref();

    return undef unless $row && $row->{metadata};

    return $self->_record_from_serialized($row->{metadata});
}

# Coerces stored MARC (XML or ISO2709 binary) into a MARC::Record.
sub _record_from_serialized {
    my ($self, $data) = @_;

    return undef unless defined $data && length $data;

    # ISO2709 binary records start with the five-character leader.
    my $record;
    if ($data =~ /^[\x00-\x1f]{5}/) {
        eval {
            require MARC::File::USMARC;
            $record = MARC::File::USMARC->decode($data);
        };
        return $record && $record->is_valid() ? $record : undef;
    }

    # Otherwise treat as MARC/XML.
    eval {
        $record = MARC::Record->new_from_xml($data, 'UTF-8', 'MARC21');
    };
    if ($@ || !$record) {
        return undef;
    }

    return $record;
}

1;

=head1 SEE ALSO

Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::SemanticStore

=cut
