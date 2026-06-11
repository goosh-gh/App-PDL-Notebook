#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok 'App::PDL::Notebook::Reactive' }

# ---------------------------------------------------------------------------
# 1. param(): 初期宣言と値の取得
# ---------------------------------------------------------------------------
App::PDL::Notebook::Reactive::reset();

my $v = App::PDL::Notebook::Reactive::param('freq', 1.0,
    type => 'number', min => 0.1, max => 5.0, step => 0.1, label => 'Frequency');
is $v, 1.0, 'param() returns default on first declaration';

# 同名 2 回目 → 値は変わらない（上書きしない）
my $v2 = App::PDL::Notebook::Reactive::param('freq', 99.0);
is $v2, 1.0, 'param() second call returns existing value, not new default';

# 別パラメータ: bool
App::PDL::Notebook::Reactive::param('logscale', 0, type => 'bool');
is App::PDL::Notebook::Reactive::value('logscale'), 0, 'bool param default 0';

# ---------------------------------------------------------------------------
# 2. button()
# ---------------------------------------------------------------------------
App::PDL::Notebook::Reactive::button('reset_zoom', label => 'Reset zoom');
is $App::PDL::Notebook::Reactive::PARAM{reset_zoom}{type}, 'button', 'button type stored';

# ---------------------------------------------------------------------------
# 3. on_change() + handle_event(): ハンドラが呼ばれ、値が更新される
# ---------------------------------------------------------------------------
my @fired;
App::PDL::Notebook::Reactive::on_change(sub {
    my ($name, $val) = @_;
    push @fired, { name => $name, val => $val };
});

App::PDL::Notebook::Reactive::handle_event('freq', 2.5);
is scalar @fired, 1, 'on_change handler called once';
is $fired[0]{name}, 'freq', 'handler receives correct name';
is $fired[0]{val},  2.5,    'handler receives correct value';
is App::PDL::Notebook::Reactive::value('freq'), 2.5, 'value updated after handle_event';

# button は値を更新しない
App::PDL::Notebook::Reactive::on_change(sub {
    my ($name, $val) = @_;
    push @fired, { name => $name, val => $val };
}, 'btn_grp');
$App::PDL::Notebook::Reactive::PARAM{reset_zoom}{group} = 'btn_grp';
App::PDL::Notebook::Reactive::handle_event('reset_zoom', 1);
is scalar @fired, 2, 'button handler called';
ok !exists $App::PDL::Notebook::Reactive::PARAM{reset_zoom}{value},
    'button has no persistent value';

# ---------------------------------------------------------------------------
# 4. descriptors(): 宣言順 + 全フィールド
# ---------------------------------------------------------------------------
my $d = App::PDL::Notebook::Reactive::descriptors();
is ref $d, 'ARRAY', 'descriptors returns arrayref';

# 宣言順: freq, logscale, reset_zoom
is $d->[0]{name}, 'freq',       'descriptor order: freq first';
is $d->[1]{name}, 'logscale',   'descriptor order: logscale second';
is $d->[2]{name}, 'reset_zoom', 'descriptor order: reset_zoom third';

is $d->[0]{type},  'number', 'freq type=number';
is $d->[0]{min},   0.1,      'freq min';
is $d->[0]{max},   5.0,      'freq max';
is $d->[0]{value}, 2.5,      'freq value reflects handle_event update';
is $d->[0]{label}, 'Frequency', 'freq label preserved';

# ---------------------------------------------------------------------------
# 5. reset(): 全状態クリア
# ---------------------------------------------------------------------------
App::PDL::Notebook::Reactive::reset();
is scalar @{ App::PDL::Notebook::Reactive::descriptors() }, 0,
    'reset() clears all params';
is scalar keys %App::PDL::Notebook::Reactive::HANDLER, 0,
    'reset() clears all handlers';

# ---------------------------------------------------------------------------
# 6. 未知 param への handle_event は何もしない（die しない）
# ---------------------------------------------------------------------------
eval { App::PDL::Notebook::Reactive::handle_event('no_such_param', 42) };
ok !$@, 'handle_event on unknown param does not die';

done_testing;
