package MojoMojoX::Convert::Kwiki;

use strict;
use warnings;

use Config::JFDI;
use Cwd qw( abs_path );
use File::Basename qw( basename );
use File::chdir;
use File::Slurp qw( read_file );
use HTML::WikiConverter;
use HTML::WikiConverter::MojoMojoMultiMarkdown;
use JSON qw( from_json );
use Kwiki ();
use Kwiki::Attachments ();
use MojoMojo::Schema;
use Scalar::Util qw( blessed );

use Moose;
use MooseX::StrictConstructor;
use Moose::Util::TypeConstraints;

with 'MooseX::Getopt::Dashes';

my $kwiki_dir = subtype as 'Str' => where { -d && -f "$_/plugins" };

has kwiki_root =>
    ( is       => 'ro',
      isa      => $kwiki_dir,
      required => 1,
    );

has default_user =>
    ( is       => 'ro',
      isa      => 'Str',
      required => 1,
    );

has _kwiki =>
    ( is       => 'ro',
      isa      => 'Kwiki',
      lazy     => 1,
      builder  => '_build_kwiki',
      init_arg => undef,
    );

has _schema =>
    ( is       => 'ro',
      isa      => 'MojoMojo::Schema',
      # we need to build this before we change our working directory
      # or else we have the wrong path for uploads.
      builder  => '_build_schema',
      init_arg => undef,
    );

my $file = subtype as 'Str' => where { -f };

has person_map_file =>
    ( is        => 'rw',
      writer    => '_set_person_map_file',
      isa       => $file,
      predicate => 'has_person_map_file',
    );

has _person_map =>
    ( is       => 'ro',
      isa      => 'HashRef',
      lazy     => 1,
      builder  => '_build_person_map',
      init_arg => undef,
    );

class_type('MojoMojo::Schema::Result::Person');

has _anonymous_user =>
    ( is       => 'ro',
      isa      => 'MojoMojo::Schema::Result::Person|Undef',
      lazy     => 1,
      builder  => '_build_anonymous_user',
      init_arg => undef,
    );

has _wiki_converter =>
    ( is       => 'ro',
      isa      => 'HTML::WikiConverter',
      lazy     => 1,
      builder  => '_build_wiki_converter',
      init_arg => undef,
    );

has path_prefix =>
    ( is      => 'ro',
      isa     => 'Str',
      default => q{},
    );

has debug =>
    ( is      => 'ro',
      isa     => 'Bool',
      default => 0,
    );

has dump_page_titles =>
    ( is      => 'ro',
      isa     => 'Bool',
      default => 0,
    );

has dump_usernames =>
    ( is      => 'ro',
      isa     => 'Bool',
      default => 0,
    );

sub BUILD
{
    my $self = shift;

    $self->_set_person_map_file( abs_path( $self->person_map_file ) )
        if $self->has_person_map_file;
}

sub run
{
    my $self = shift;

    # Kwiki just assumes it is running from its root directory.
    local $CWD = $self->kwiki_root();

    if ( $self->dump_page_titles() )
    {
        print "\n";
        print "All page titles in the Kwiki wiki ...\n";
        print $_->title, "\n"
            for $self->_kwiki()->hub()->pages()->all();
    }

    if ( $self->dump_usernames() )
    {
        print "\n";
        print "All usernames in the Kwiki wiki ...\n";

        my %names;
        for my $page ( $self->_kwiki()->hub()->pages()->all() )
        {
            for my $metadata ( reverse @{ $page->history() } )
            {
                $names{ $metadata->{edit_by} } = 1;
            }
        }

        print "$_\n" for sort keys %names;
    }

    exit if $self->dump_page_titles() || $self->dump_usernames();

    for my $page ( $self->_kwiki()->hub()->pages()->all() )
    {
        $self->_convert_page($page);
    }
}

sub _build_kwiki
{
    my $self = shift;

    # Magic voodoo to make Kwiki work. I don't really care to dig too
    # deep into this.
    my $kwiki = Kwiki->new();
    my $hub = $kwiki->load_hub( 'config*.*', -plugins => 'plugins' );
    $hub->registry()->load();
    $hub->add_hooks();
    $hub->pre_process();
    $hub->preload();

    return $kwiki;
}

sub _build_schema
{
    my $jfdi = Config::JFDI->new( name => 'MojoMojo' );

    my $config = $jfdi->get;

    my ($dsn, $user, $pass);
    if ( ref $config->{'Model::DBIC'}->{'connect_info'} )
    {
        ($dsn, $user, $pass) =
            @{ $config->{'Model::DBIC'}->{'connect_info'} };
    }
    else
    {
        $dsn = $config->{'Model::DBIC'}->{'connect_info'};
    }

    my $schema = MojoMojo::Schema->connect( $dsn, $user, $pass )
        or die 'Failed to connect to database';

    $schema->attachment_dir( abs_path( $config->{attachment_dir} ) );

    return $schema;
}

sub _convert_page
{
    my $self = shift;
    my $page = shift;

    return if $page->title() eq 'Help';

    my $mm_title = $self->_convert_title( $page->title );

    $self->_debug( q{} );
    $self->_debug( "Converting page " . $page->title() . " to $mm_title" );

    my $mm_page;
    for my $metadata ( reverse @{ $page->history() } )
    {
        $self->_debug( " ... revision $metadata->{revision_id}" );

        my $person = $self->_convert_person( $metadata->{edit_by} );

        my ( $path_pages, $proto_pages ) =
            $self->_schema->resultset('Page')->path_pages($mm_title);

        if (@{$proto_pages})
        {
            $path_pages = $self->_schema->resultset('Page')->create_path_pages
                ( path_pages  => $path_pages,
                  proto_pages => $proto_pages,
                  creator     => $person,
                );
        }

        $mm_page = $path_pages->[-1];

        my $body =
            $self->_convert_body
                ( scalar $self->_kwiki->hub->archive->fetch
                      ( $page, $metadata->{revision_id} )
                );

        $mm_page->update_content
            ( creator => $person,
              body    => $body,
            );

        my $content = $mm_page->content();

        $content->created( $metadata->{edit_unixtime} );
        $content->update;
    }

    $self->_convert_attachments( $page, $mm_page );
}

sub _convert_title
{
    my $self  = shift;
    my $title = shift;

    my $mm_title;
    if ( $title eq 'HomePage' )
    {
        $mm_title = q{};
    }
    else
    {
        $mm_title = $self->_de_studly($title);
    }

    return $self->path_prefix . q{/} . $mm_title;
}

sub _de_studly
{
    my $eslf  = shift;
    my $title = shift;

    $title =~ s/([^A-Z])([A-Z])/$1 $2/g;

    return $title;
}

sub _convert_person
{
    my $self       = shift;
    my $kwiki_user = shift;

    $kwiki_user = $self->default_user()
        unless defined $kwiki_user && length $kwiki_user;

    my $person;
    if ( $kwiki_user eq 'AnonymousGnome' )
    {
        $person = $self->_anonymous_user();

        unless ( defined $person )
        {
            die "Could not find an anonymous user in the Mojomojo database!";
        }
    }
    else
    {
        return $self->_person_map()->{$kwiki_user}
            if blessed $self->_person_map()->{$kwiki_user};

        $self->_debug( "Looking for user mapping from $kwiki_user" );

        $person = $self->_person_map->{$kwiki_user};

        if ($person)
        {
            $self->_debug( " ... found an explicit mapping to $person->{login}" );
        }
        else {
            $self->_debug( ' ... using implicit mapping' );
        }

        $person ||= {};
        for my $key ( qw( login pass name email ) )
        {
            next if exists $person->{$key};

            my $meth = '_default_' . $key . '_for_person';
            $person->{$key} = $self->$meth( $kwiki_user, $person );
        }

        my $person_obj =
            $self->_schema()->resultset('Person')
                 ->search( { login => $person->{login} } )->first();

        if ($person_obj)
        {
            $self->_debug( ' ... found a user in the database' );
        }
        else
        {
            my $status = $person->{active} ? 'active' : 'inactive';
            my $msg = qq{ ... creating a new $status user, password is "$person->{pass}"};

            $self->_debug($msg);

            $person_obj = $self->_schema()->resultset('Person')->create($person);
        }

        $self->_person_map->{$kwiki_user} = $person_obj;
    }
}

sub _default_pass_for_person
{
    return 'change me';
}

sub _default_login_for_person
{
    my $self       = shift;
    my $kwiki_user = shift;

    return lc $kwiki_user;
}

sub _default_name_for_person
{
    my $self       = shift;
    my $kwiki_user = shift;

    return $kwiki_user;
}

sub _default_email_for_person
{
    my $self       = shift;
    my $kwiki_user = shift;

    return $kwiki_user . '@localhost';
}

sub _build_person_map
{
    my $self = shift;

    my $map;
    $map = from_json( read_file( $self->person_map_file() ) )
        if $self->has_person_map_file;
    $map ||= {};

    return $map;
}

sub _build_anonymous_user
{
    my $self = shift;

    my $pref =
        $self->_schema()->resultset('Preference')->find_or_create( { prefkey => 'anonymous_user' } );

    my $anonymous = $pref->prefvalue()
        or return;

    return $self->_schema()->resultset('Person')->search( {login => $anonymous} )->first();
}

sub _convert_body
{
    my $self = shift;
    my $body = shift;

    return q{} unless defined $body && length $body;

    return
        $self->_wiki_converter()->html2wiki
            ( $self->_kwiki->hub->formatter->text_to_html
                  ( Encode::encode( 'utf8', $body ) )
            );
}

sub _build_wiki_converter
{
    my $self = shift;

    return
        HTML::WikiConverter->new
            ( dialect  => 'MojoMojoMultiMarkdown',
              wiki_uri => [ sub { $self->_convert_wiki_link(@_) } ],
            );
}

sub _convert_wiki_link
{
    my $self      = shift;
    my $converter = shift;
    my $uri       = shift;

    if ( my ($title) = $uri =~ /index.cgi\?(\w+)/ )
    {
        return $self->_convert_title($title);
    }

    return;
}

sub _convert_attachments
{
    my $self    = shift;
    my $page    = shift;
    my $mm_page = shift;

    return unless $self->_kwiki()->hub()->attachments()->get_attachments( $page->id() );

    my $dir = join q{/}, $self->_kwiki()->hub()->attachments()->plugin_directory(), $page->id();

    for my $file ( @{ $self->_kwiki()->hub()->attachments()->files() } )
    {
        $self->_debug( ' ... attachment for ' . $page->title() . ' - ' . $file->name() );

        my $file_path = join q{/}, $dir, $file->name();

        $self->_schema()->resultset('Attachment')
             ->create_from_file( $mm_page, $file->name(), $file_path );
    }
}

sub _debug
{
    my $self = shift;

    return unless $self->debug();

    my $msg = shift;

    print STDERR $msg, "\n";
}

{
    use Spoon::Hub;

    package Spoon::Hub;

    no warnings 'redefine';

    # shuts up a warning during global destruction
    sub remove_hooks {
        my $self = shift;
        my $hooks = $self->all_hooks;
        while (@$hooks) {
            my $hook = pop(@$hooks)
                or next;
            $hook->unhook;
        }
    }
}


no Moose;
no Moose::Util::TypeConstraints;

1;
