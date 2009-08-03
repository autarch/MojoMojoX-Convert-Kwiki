package MojoMojoX::Convert::Kwiki;

use strict;
use warnings;

use Config::JFDI;
use Cwd qw( abs_path );
use Encode qw( decode encode );
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
use URI::Escape qw( uri_unescape );

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

    $self->_update_backlinks_and_search_index();
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

    $page->title( $self->_proper_kwiki_title( $page->id ) );

    return if $page->title() eq 'Help';

    my $mm_title = $self->_convert_title( $page->title );

    $self->_debug( q{} );
    $self->_debug( "Converting page " . $page->title() . " to $mm_title" );

    my @history = reverse @{ $page->history() };

    my ( $path_pages, $proto_pages ) =
        $self->_schema->resultset('Page')->path_pages($mm_title);

    if ( @{ $proto_pages } )
    {
        my $creator = $self->_convert_person( $history[0]->{edit_by} );

        $path_pages = $self->_schema->resultset('Page')->create_path_pages
            ( path_pages  => $path_pages,
              proto_pages => $proto_pages,
              creator     => $creator,
            );
    }

    my $mm_page = $path_pages->[-1];

    my $attachment_map = $self->_convert_attachments( $page, $mm_page );

    for my $metadata (@history)
    {
        $self->_debug( " ... revision $metadata->{revision_id}" );

        my $person = $self->_convert_person( $metadata->{edit_by} );

        my $body =
            $self->_convert_body
                ( $attachment_map,
                  scalar $self->_kwiki->hub->archive->fetch
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
}

# Kwiki completely breaks utf8 in page titles with its conversion
# routines. This redoes the conversion and unbreaks utf8.
sub _proper_kwiki_title
{
    my $self = shift;
    my $id   = shift;

    my $title = uri_unescape($id);

    return decode( 'utf8', $title );
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
        for my $key ( qw( active login pass name email ) )
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

sub _default_active_for_person
{
    return -1;
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

sub _convert_attachments
{
    my $self    = shift;
    my $page    = shift;
    my $mm_page = shift;

    return unless $self->_kwiki()->hub()->attachments()->get_attachments( $page->id() );

    my $dir = join q{/}, $self->_kwiki()->hub()->attachments()->plugin_directory(), $page->id();

    my %map;
    for my $file ( @{ $self->_kwiki()->hub()->attachments()->files() } )
    {
        $self->_debug( ' ... attachment ' . $file->name() );

        my $file_path = join q{/}, $dir, $file->name();

        my $att =
            $self->_schema()->resultset('Attachment')
                 ->create_from_file( $mm_page, $file->name(), $file_path );

        $map{ $file->name() } = $att->id();
    }

    return \%map;
}

# gibberish that will not be present in any real page. We can use this
# to delimit things that need to be dealt with _after_ the kwiki ->
# html -> markdown conversion.
my $Marker = 'asfkjsdkglsjdglkjsga09dsug0329jt3poi3p41o6j24963109ytu0cgsv';
sub _convert_body
{
    my $self           = shift;
    my $attachment_map = shift;
    my $body           = shift;

    return q{} unless defined $body && length $body;

    my $counter = 1;
    my %post_convert;
    $body =~ s/\{file:?\s*([^}]+)}/
               $post_convert{$counter++} = [ 'attachment', $1 ];
               $Marker . ':' . ( $counter - 1 )/eg;

    # This encode/decode stuff should not be necessary, but
    # HTML::WikiConverter blindly calls decode and encode internally on the
    # data, which is broken and wrong, but we have to dealw ith it.
    $body = encode('utf8', $body );
    my $markdown =
                $self->_wiki_converter()->html2wiki
                    ( $self->_kwiki->hub->formatter->text_to_html($body) );

    $markdown = decode('utf8', $body);

    $markdown =~ s/$Marker:(\d+)/
                   $self->_post_convert( $post_convert{$1}, $attachment_map )/eg;

    return $markdown;
}

sub _post_convert
{
    my $self           = shift;
    my $action         = shift;
    my $attachment_map = shift;

    if ( $action->[0] eq 'attachment' )
    {
        $self->_attachment_link( $action->[1], $attachment_map );
    }
    else
    {
        die "Unknown post-covert action: $action->[0]";
    }
}

sub _attachment_link
{
    my $self           = shift;
    my $filename       = shift;
    my $attachment_map = shift;

    return q{} unless $attachment_map->{$filename};

    return "[$filename](.attachment/$attachment_map->{$filename})";
}

sub _build_wiki_converter
{
    my $self = shift;

    return
        HTML::WikiConverter->new
            ( dialect         => 'MojoMojoMultiMarkdown',
              escape_entities => 0,
              wiki_uri        => [ sub { $self->_convert_wiki_link(@_) } ],
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

sub _update_backlinks_and_search_index
{
#         $c->model("DBIC::Page")->set_paths($page);
#         $c->model('Search')->index_page($page)
#             unless $c->pref('disable_search');
#         $page->content->store_links();
#         $c->model('DBIC::WantedPage')
#           ->search( { to_path => $c->stash->{path} } )->delete();

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
