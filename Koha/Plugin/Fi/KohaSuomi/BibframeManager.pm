package Koha::Plugin::Fi::KohaSuomi::BibframeManager;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
## We will also need to include any Koha libraries we want to access
use C4::Context;
use utf8;
use JSON;
use File::Slurp;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Database;
use Koha::Plugin::Fi::KohaSuomi::BibframeManager::Modules::Bibframe;

## Here we set our plugin version
our $VERSION = "1.0.0";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Bibframe Manager',
    author          => 'Johanna Räisä',
    date_authored   => '2025-11-11',
    date_updated    => '2025-11-11',
    minimum_version => '25.05',
    maximum_version => '',
    version         => $VERSION,
    description     => 'Manage Bibframe metadata - convert MARC21 to Bibframe, store, retrieve, and export in multiple RDF formats',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual 
    my $self = $class->SUPER::new($args);

    return $self;
}

## The 'tool' method provides the UI for Bibframe record creation
sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'tool.tt' });
    print $cgi->header(-charset => 'utf-8');
    print $template->output();
}

## API routes configuration
sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_dir = $self->mbf_dir();
    my $spec_file = $spec_dir . '/openapi.yaml';

    my $schema = JSON::Validator::Schema::OpenAPIv2->new;
    $schema->resolve( $spec_file );

    return $schema->bundle->data;
}

## API namespace
sub api_namespace {
    my ( $self ) = @_;
    
    return 'kohasuomi';
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    my $sql_dir = $self->mbf_dir() . '/sql';
    my @sql_files = (
        '01_core_tables.sql',
        '02_summary_tables.sql',
        '03_component_parts.sql',
        '04_format_mappings_graphs.sql',
        '05_add_item_id.sql',
    );

    my $dbh = C4::Context->dbh;
    for my $sql_file (@sql_files) {
        my $sql_path = "$sql_dir/$sql_file";
        my $sql_content = eval { read_file($sql_path) };
        if ($@) {
            warn "Failed to read SQL file $sql_path: $@";
            return 0;
        }
        $dbh->do($sql_content) or do {
            warn "Failed to execute SQL from $sql_file: " . $dbh->errstr;
            return 0;
        };
    }

    return 1;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $sql_dir = $self->mbf_dir() . '/sql';
    my @sql_files = (
        '01_core_tables.sql',
        '06_rename_manif_summary_to_instance.sql',
        '02_summary_tables.sql',
        '03_component_parts.sql',
        '04_format_mappings_graphs.sql',
        '05_add_item_id.sql',
    );

    my $dbh = C4::Context->dbh;
    for my $sql_file (@sql_files) {
        my $sql_path = "$sql_dir/$sql_file";
        my $sql_content = eval { read_file($sql_path) };
        if ($@) {
            warn "Failed to read SQL file $sql_path: $@";
            return 0;
        }
        $dbh->do($sql_content) or do {
            warn "Failed to execute SQL from $sql_file: " . $dbh->errstr;
            return 0;
        };
    }

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $dbh = C4::Context->dbh;
    my @tables = qw(
        record_graph_resources
        record_graphs
        record_format_mappings
        record_component_parts
        record_agent_summary
        record_manif_summary
        record_work_summary
        record_properties
        record_links
        record_resources
    );

    for my $table (@tables) {
        $dbh->do("DROP TABLE IF EXISTS $table");
    }

    return 1;
}

1;

