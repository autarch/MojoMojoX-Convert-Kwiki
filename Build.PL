use strict;
use warnings;

use Module::Build;

my $builder = Module::Build->new
    ( module_name        => 'MojoMojoX::Convert::Kwiki',
      license            => 'perl',
      requires           => { 'Config::JFDI'                  => '0',
                              'Cwd'                           => '0',
                              'File::Basename'                => '0',
                              'File::chdir'                   => '0',
                              'File::Slurp'                   => '0',
                              'HTML::WikiConverter'           => '0',
                              'HTML::WikiConverter::Markdown' => '0',
                              'JSON'                          => '0',
                              'Kwiki'                         => '0',
                              'Kwiki::Attachments'            => '0',
                              'MojoMojo'                      => '0',
                              'Moose'                         => '0',
                              'MooseX::Getopt'                => '0',
                              'MooseX::StrictConstructor'     => '0',
                              'Scalar::Util'                  => '0',
                            },
      build_requires     => { 'Test::More' => '0',
                            },
      create_readme      => 1,
      sign               => 1,
      create_makefile_pl => 'traditional',
    );

$builder->create_build_script();
