package HTML::WikiConverter::MojoMojoMultiMarkdown;

use strict;
use warnings;

use base 'HTML::WikiConverter::Markdown';

sub rules
{
    my $self = shift;

    my $rules = $self->SUPER::rules(@_);

    return
        { %{$rules},
          table => { block => 1,
                     end => \&_table_end,
                   },
          tr    => {start       => \&_tr_start,
                    end         => qq{ |\n},
                    line_format => 'single'
                   },
          td    => { start => \&_td_start,
                     end   => q{ } },
          th    => { alias   => 'td', },
          a     => { replace => \&_link, },
        };
}

sub _link
{
    my ( $self, $node, $rules ) = @_;

    my $url = $node->attr('href') || '';

    if ( my $title = $self->get_wiki_page($url) )
    {
        return '[[' . $title . ']]';
    }
    else
    {
        return $self->SUPER::_link( $node, $rules );
    }
}

sub _table_end
{
    my $self = shift;

    delete $self->{__row_count__};
    delete $self->{__th_count__};

    return q{};
}


# This method is first called on the _second_ row, go figure
sub _tr_start
{
    my $self = shift;

    my $start = q{};
    if ( $self->{__row_count__} == 2 )
    {
        $start = '|---' x $self->{__th_count__};
        $start .= qq{|\n};
    }

    $self->{__row_count__}++;

    return $start;
}

# This method is called for the first cell in a table, and before the
# first call to table or tr start!
sub _td_start
{
    my $self = shift;

    $self->{__row_count__} = 1
        unless exists $self->{__row_count__};

    if ( exists $self->{__th_count__} )
    {
        $self->{__th_count__}++;
    }
    else
    {
        $self->{__th_count__} = 1;
    }

    return '| ';
}

1;
