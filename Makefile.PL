use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'App::PDL::Notebook',
    VERSION_FROM     => 'lib/App/PDL/Notebook.pm',
    ABSTRACT         => 'A lightweight, Jupyter-style notebook for PDL without ZeroMQ or Jupyter',
    AUTHOR           => 'goosh-gh',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.020',

    EXE_FILES => [ 'script/pdl-notebook', 'script/pdl-notebook-kernel' ],

    PREREQ_PM => {
        'Mojolicious'  => '9.0',
        'JSON::PP'     => 0,
        'MIME::Base64' => 0,
        'Scalar::Util' => 0,
        'IPC::Open2'   => 0,
    },

    # Recommended but not required -- the core is PDL-agnostic and degrades:
    #   Lexical::Persistence   `my` variables persist across cells
    #   PDL                    the point of the notebook
    # NOT on CPAN (install from GitHub, see README): PDL::Graphics::Cairo, PDL::IO::PNG, better to have these!
    TEST_REQUIRES => { 'Test::More' => 0 },

    META_MERGE => {
        'meta-spec' => { version => 2 },
        prereqs => {
            runtime => {
                recommends => {
                    'Lexical::Persistence' => 0,
                    'PDL'                  => 0,
                },
            },
        },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/goosh-gh/App-PDL-Notebook.git',
                web  => 'https://github.com/goosh-gh/App-PDL-Notebook',
            },
        },
    },
);
