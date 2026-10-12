#!/usr/bin/perl
#
# generate_bffi_rename.pl
#
# Generates config/bffi_rename.yaml from the vendored BFFI ontology
# (config/lkd.rdf). The output is the bf:/bflc: -> bffi: rename table used by
# Modules::BFFIProjector to produce a closed-namespace BFFI graph.
#
# This mirrors the ontology-driven mapping extraction used by the National
# Library of Finland's bffi-conversion-pipeline: the rename table is derived
# from owl:equivalentClass / owl:equivalentProperty and the rdfs:subClassOf /
# rdfs:subPropertyOf hierarchy (transitively inherited), never hand-maintained.
#
# Usage:
#   perl tools/generate_bffi_rename.pl            # write config/bffi_rename.yaml
#   perl tools/generate_bffi_rename.pl --check     # fail (exit 1) on drift
#   perl tools/generate_bffi_rename.pl --output P  # write to another path
#
# Copyright 2025 Koha-Suomi Oy
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use File::Spec;
use File::Basename qw(dirname);
use XML::LibXML;
use YAML::XS ();

use constant BFFI_NS => 'http://urn.fi/URN:NBN:fi:schema:bffi:';
use constant BF_NS   => 'http://id.loc.gov/ontologies/bibframe/';
use constant BFLC_NS => 'http://id.loc.gov/ontologies/bflc/';
use constant OWL_NS  => 'http://www.w3.org/2002/07/owl#';
use constant RDFS_NS => 'http://www.w3.org/2000/01/rdf-schema#';
use constant RDF_NS  => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';

my %PREFIX = (
    BFFI_NS() => 'bffi',
    BF_NS()   => 'bf',
    BFLC_NS() => 'bflc',
    OWL_NS()  => 'owl',
    RDFS_NS() => 'rdfs',
    RDF_NS()  => 'rdf',
);

sub main {
    my $check = 0;
    my $output_opt;
    my @args = @ARGV;
    while (@args) {
        my $arg = shift @args;
        if ($arg eq '--check') {
            $check = 1;
        }
        elsif ($arg eq '--output') {
            $output_opt = shift @args;
            die "--output requires a path\n" unless defined $output_opt;
        }
        else {
            die "Unknown option: $arg\n";
        }
    }

    my $config_dir = File::Spec->catdir(
        $Bin, '..', 'Koha', 'Plugin', 'Fi', 'KohaSuomi', 'BibframeManager', 'config'
    );
    for my $f (qw(lkd.rdf bibframe.rdf lkd.ttl)) {
        my $candidate = File::Spec->catfile($config_dir, $f);
        $config_dir = dirname($candidate) if -f $candidate;
    }

    my $source = File::Spec->catfile($config_dir, 'lkd.rdf');
    unless (-f $source) {
        die "BFFI ontology not found: $source\n";
    }

    my $output = $output_opt
        || File::Spec->catfile($config_dir, 'bffi_rename.yaml');

    my $data = extract_rename_table($source, $config_dir);
    my $content = render_yaml($data);

    if ($check) {
        my $existing = -f $output ? slurp($output) : '';
        if ($existing ne $content) {
            warn "bffi_rename.yaml is out of date; run tools/generate_bffi_rename.pl\n";
            return 1;
        }
        print "bffi_rename.yaml is up to date\n";
        return 0;
    }

    open my $fh, '>:encoding(UTF-8)', $output
        or die "Cannot write $output: $!";
    print {$fh} $content;
    close $fh;

    printf "Wrote %s\n", $output;
    printf "  classes:       %d\n", scalar keys %{ $data->{classes} };
    printf "  properties:    %d\n", scalar keys %{ $data->{properties} };
    printf "  subproperties: %d\n", scalar keys %{ $data->{subproperties} };
    printf "  subclasses:    %d\n", scalar keys %{ $data->{subclasses} };
    printf "  value vocabularies for %d properties\n",
        scalar keys %{ $data->{value_vocabularies} };
    return 0;
}

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

sub extract_rename_table {
    my ($source, $config_dir) = @_;

    my $BFFI = BFFI_NS();
    my $BF   = BF_NS();
    my $BFLC = BFLC_NS();
    my $OWL  = OWL_NS();
    my $RDFS = RDFS_NS();
    my $RDF  = RDF_NS();

    my $parser = XML::LibXML->new();
    my $doc    = $parser->parse_file($source);
    my $root   = $doc->documentElement();

    my %terms;    # bffi URI -> { kind, equivalent, narrow, vocab => [] }
    my %order;

    for my $desc ($root->findnodes('//*[local-name()="Description"]')) {
        my $about = $desc->getAttributeNS($RDF, 'about');
        next unless $about && $about =~ /^\Q$BFFI\E/;

        my ($kind, @equiv, @narrow, @vocab);

        for my $child (grep { $_->nodeType == 1 } $desc->childNodes()) {
            my $ln = $child->localName() || '';
            my $ns = $child->namespaceURI() || '';
            my $res = $child->getAttributeNS($RDF, 'resource') || '';

            if ($ln eq 'type' && $ns eq $RDF) {
                $kind = 'class'    if $res eq "${OWL}Class";
                $kind = 'property' if !$kind && $res =~ /^\Q$OWL\E(?:Object|Datatype|Annotation|Symmetric)Property$/;
            }
            elsif ($ln eq 'equivalentClass' && $ns eq $OWL) {
                push @equiv, $res if $res =~ /^(?:\Q$BF\E|\Q$BFLC\E)/;
            }
            elsif ($ln eq 'equivalentProperty' && $ns eq $OWL) {
                push @equiv, $res if $res =~ /^(?:\Q$BF\E|\Q$BFLC\E)/;
            }
            elsif ($ln eq 'subClassOf' && $ns eq $RDFS) {
                push @narrow, $res if $res =~ /^(?:\Q$BF\E|\Q$BFLC\E)/;
            }
            elsif ($ln eq 'subPropertyOf' && $ns eq $RDFS) {
                push @narrow, $res if $res =~ /^(?:\Q$BF\E|\Q$BFLC\E)/;
            }
            elsif ($ln eq 'relatedValueVocabulary') {
                push @vocab, $res if $res;
            }
        }

        next unless $kind;
        next unless @equiv || @narrow;

        $order{$about} ||= scalar keys %order;
        $terms{$about} = {
            kind       => $kind,
            equivalent => $equiv[0],
            narrow     => $narrow[0],
            vocab      => [ sort @vocab ],
        };
    }

    my %classes;
    my %properties;
    my %subproperties;
    my %subclasses;
    my %value_vocabularies;

    for my $uri (sort { $order{$a} <=> $order{$b} } keys %terms) {
        my $t = $terms{$uri};
        my $target = short($uri);
        next unless $target;

        my $clean_from  = $t->{equivalent} ? short($t->{equivalent}) : undef;
        my $narrow_from = $t->{narrow}     ? short($t->{narrow})     : undef;

        if ($t->{kind} eq 'class') {
            _add_mapping(\%classes,    $clean_from,  $target, 'class');
            _add_mapping(\%subclasses, $narrow_from, $target, 'subclass');
        }
        else {
            _add_mapping(\%properties,    $clean_from,  $target, 'property');
            _add_mapping(\%subproperties, $narrow_from, $target, 'subproperty');
        }

        if ($t->{vocab} && @{ $t->{vocab} }) {
            $value_vocabularies{$target} = $t->{vocab};
        }
    }

    return {
        version            => 1,
        source             => 'config/lkd.rdf',
        classes            => \%classes,
        properties         => \%properties,
        subclasses         => \%subclasses,
        subproperties      => \%subproperties,
        value_vocabularies => \%value_vocabularies,
    };
}

# Record a single mapping. When several bffi terms map from the same bf/bflc
# term (a "narrower" subPropertyOf fan-out), prefer the target whose local name
# matches the source; otherwise keep the first one seen and warn.
sub _add_mapping {
    my ($map, $from, $target, $label) = @_;
    return unless $from;

    my $new_exact = _localname($from) eq _localname($target) ? 1 : 0;

    if (my $prev = $map->{$from}) {
        return if $prev eq $target;
        my $prev_exact = _localname($from) eq _localname($prev) ? 1 : 0;
        if ($new_exact && !$prev_exact) {
            $map->{$from} = $target;
        }
        elsif ($new_exact == $prev_exact) {
            warn "$label conflict: $from -> $prev vs $target (kept $prev)\n";
        }
        return;
    }
    $map->{$from} = $target;
}

sub _localname {
    my ($prefixed) = @_;
    my ($local) = $prefixed =~ /^[^:]+:(.*)$/;
    return defined $local ? $local : $prefixed;
}

# Map a full URI to its prefixed short form, using the known namespaces.
sub short {
    my ($uri) = @_;
    return undef unless defined $uri;
    for my $ns (keys %PREFIX) {
        my $prefix = $PREFIX{$ns};
        if (index($uri, $ns) == 0) {
            return "$prefix:" . substr($uri, length($ns));
        }
    }
    return undef;
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

sub render_yaml {
    my ($data) = @_;

    no warnings 'once';
    $YAML::XS::SortKeys = 1;
    my %body = (
        version            => $data->{version},
        source             => $data->{source},
        namespaces         => {
            bf   => BF_NS(),
            bflc => BFLC_NS(),
            bffi => BFFI_NS(),
        },
        classes            => $data->{classes},
        properties         => $data->{properties},
        subclasses         => $data->{subclasses},
        subproperties      => $data->{subproperties},
        value_vocabularies => $data->{value_vocabularies},
    );

    my $yaml = YAML::XS::Dump(\%body);

    my $header = <<"HEADER";
# GENERATED FILE - do not edit by hand.
#
# BIBFRAME -> BFFI rename table, derived from the vendored BFFI ontology
# (config/lkd.rdf). Regenerate with:
#
#     perl tools/generate_bffi_rename.pl
#
# `classes` / `properties` are clean equivalences (owl:equivalentClass /
# owl:equivalentProperty). `subclasses` / `subproperties` are narrower
# mappings declared via rdfs:subClassOf / rdfs:subPropertyOf and are applied
# only when no clean mapping matches. `value_vocabularies` lists the MTS value
# vocabulary terms a property is associated with (bffi-meta:relatedValueVocabulary).
HEADER

    return $header . $yaml;
}

sub slurp {
    my ($file) = @_;
    open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read $file: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

exit main();
