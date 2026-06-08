use strict;
use warnings;
use Test::More;

use_ok('App::PDL::Notebook');
use_ok('App::PDL::Notebook::Display');
use_ok('App::PDL::Notebook::Reactive');

# Reactive registry round-trip (no PDL / no kernel needed)
App::PDL::Notebook::Reactive::reset();
my $got;
App::PDL::Notebook::Reactive::param('cutoff', 0.5, type => 'number', min => 0, max => 1);
App::PDL::Notebook::Reactive::on_change(sub { $got = $_[1] });
is(App::PDL::Notebook::Reactive::value('cutoff'), 0.5, 'param stores default');
App::PDL::Notebook::Reactive::handle_event('cutoff', 0.8);
is(App::PDL::Notebook::Reactive::value('cutoff'), 0.8, 'event updates value');
is($got, 0.8, 'on_change closure fired');

# repr() falls back to stringification for plain values
my ($mime, $data) = App::PDL::Notebook::Display::repr(42);
is($mime, 'text/plain', 'repr mime for scalar');
is($data, '42', 'repr data for scalar');

done_testing;
