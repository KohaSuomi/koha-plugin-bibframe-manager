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
our $VERSION = "2.0.0";

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

## Executes one SQL file statement by statement. The database connection
## does not accept multi-statement queries, so the file cannot be passed
## to $dbh->do() in one piece.
sub _run_sql_file {
    my ( $self, $dbh, $sql_path ) = @_;

    my $sql_content = eval { read_file($sql_path) };
    if ($@) {
        warn "Failed to read SQL file $sql_path: $@";
        return 0;
    }

    # Strip -- comments (they may contain semicolons), then split on ;
    $sql_content =~ s/--[^\n]*//g;
    for my $statement ( split /;/, $sql_content ) {
        $statement =~ s/^\s+//;
        $statement =~ s/\s+$//;
        next unless length $statement;
        $dbh->do($statement) or do {
            warn "Failed to execute SQL from $sql_path: " . $dbh->errstr;
            return 0;
        };
    }

    return 1;
}

## Adds columns introduced after the initial table DDL. CREATE TABLE
## IF NOT EXISTS cannot add columns to tables that already exist, so
## upgrades of installed schemas need explicit ALTER statements.
sub _ensure_columns {
    my ( $self, $dbh ) = @_;

    my @columns = (
        [ 'record_links', 'updated_at', 'TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP' ],
        [ 'record_instance_summary', 'identifiers', 'JSON' ],
    );

    for my $c (@columns) {
        my ( $table, $column, $ddl ) = @$c;
        my ($exists) = $dbh->selectrow_array(
            'SELECT COUNT(*) FROM information_schema.COLUMNS
              WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?',
            undef, $table, $column
        );
        next if $exists;
        $dbh->do("ALTER TABLE $table ADD COLUMN $column $ddl") or do {
            warn "Failed to add $table.$column: " . $dbh->errstr;
            return 0;
        };
    }

    return 1;
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
        '05_work_clustering.sql',
    );

    my $dbh = C4::Context->dbh;
    for my $sql_file (@sql_files) {
        $self->_run_sql_file( $dbh, "$sql_dir/$sql_file" ) or return 0;
    }
    $self->_ensure_columns($dbh) or return 0;

    return 1;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $sql_dir = $self->mbf_dir() . '/sql';
    my @sql_files = (
        '01_core_tables.sql',
        '02_summary_tables.sql',
        '03_component_parts.sql',
        '04_format_mappings_graphs.sql',
        '05_work_clustering.sql',
    );

    my $dbh = C4::Context->dbh;
    for my $sql_file (@sql_files) {
        $self->_run_sql_file( $dbh, "$sql_dir/$sql_file" ) or return 0;
    }
    $self->_ensure_columns($dbh) or return 0;

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
        work_match_candidates
        record_agent_summary
        record_instance_summary
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

