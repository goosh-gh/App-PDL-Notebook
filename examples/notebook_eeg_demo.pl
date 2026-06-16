#!/usr/bin/env perl
# notebook_eeg_demo.pl — App-PDL-Notebook 向け EEG ビューア（LTTB統合）
#
# 使い方:
#   # App-PDL-Notebook のセル内:
#   do 'examples/notebook_eeg_demo.pl';
#
#   # スタンドアロン（PNG 確認):
#   perl examples/notebook_eeg_demo.pl
#   # → notebook_eeg_demo_out.png を出力
#
# 高速化の仕組み:
#   1. on_change: スライダ変化でセル全体ではなくクロージャのみ再実行
#   2. LTTB (PDL::Graphics::Cairo::LTTB): 20ch×N点→表示幅×2点に間引き
#
# 依存:
#   PDL::Graphics::Cairo (github.com/goosh-gh/PDL-Graphics-Cairo)
#   App::PDL::Notebook   (github.com/goosh-gh/App-PDL-Notebook) ← Notebook内のみ

use strict;
use warnings;
no warnings 'redefine';
use utf8;
use PDL;
eval { require PDL::NiceSlice; PDL::NiceSlice->import; 1 };  # あれば使う
use PDL::Graphics::Cairo qw(figure);
use PDL::Graphics::Cairo::LTTB qw(lttb);
# App::PDL::Notebook::Display は Notebook 内のみ必須。
# スタンドアロン実行時はなくても動くよう require で遅延ロード。
# use App::PDL::Notebook::Display ();   # ← BEGIN時評価なので削除

# ===========================================================================
# 0. 合成 EEG データ生成（実データは PDL::EEG::IO::NihonKohden で読む）
# ===========================================================================

# 国際10-20法 20チャンネル、5×5グリッド配置
our @LAYOUT = (
    # row 0: Fp1/Fp2 を F3/F4 の真上（c=1,3）に配置
    { r=>0, c=>1, n=>'Fp1' }, { r=>0, c=>3, n=>'Fp2' },
    # row 1: 前頭部フル
    { r=>1, c=>0, n=>'F7'  }, { r=>1, c=>1, n=>'F3'  }, { r=>1, c=>2, n=>'Fz'  },
    { r=>1, c=>3, n=>'F4'  }, { r=>1, c=>4, n=>'F8'  },
    # row 2: 中心部フル
    { r=>2, c=>0, n=>'T3'  }, { r=>2, c=>1, n=>'C3'  }, { r=>2, c=>2, n=>'Cz'  },
    { r=>2, c=>3, n=>'C4'  }, { r=>2, c=>4, n=>'T4'  },
    # row 3: 頭頂部フル
    { r=>3, c=>0, n=>'T5'  }, { r=>3, c=>1, n=>'P3'  }, { r=>3, c=>2, n=>'Pz'  },
    { r=>3, c=>3, n=>'P4'  }, { r=>3, c=>4, n=>'T6'  },
    # row 4: O1/O2 を P3/P4 の真下（c=1,3）; c=0,2,4 は情報/スケールパネル
    { r=>4, c=>1, n=>'O1'  }, { r=>4, c=>3, n=>'O2'  },
);
my $N_CH   = scalar @LAYOUT;
my $SRATE  = 1000;           # Hz
my $T_SEC  = 3.0;
my $N_SAMP = int($SRATE * $T_SEC);

my $t_all = sequence($N_SAMP) / $SRATE * 1000;  # ms 単位

my $eeg = do {
    srand(42);
    my @ch_data;
    for my $i (0 .. $N_CH - 1) {
        my $amp   = 0.5 + rand(1.0);
        my $alpha = $amp * 20 * sin(2 * 3.14159265 * 10 * sequence($N_SAMP) / $SRATE);
        my $gamma = $amp *  5 * sin(2 * 3.14159265 * 40 * sequence($N_SAMP) / $SRATE);
        my $noise = grandom($N_SAMP) * 8;
        my $ch    = $alpha + $gamma + $noise;
        # N200成分: 中央電極 (i=8..12) に 180-350ms のネガティブ偏向
        if ($i >= 8 && $i <= 12) {
            my $t200 = int(0.265 * $SRATE);   # ピーク ~265ms
            my $sig  = int(0.040 * $SRATE);   # σ ~40ms
            my $gauss = -35 * exp(-(sequence($N_SAMP) - $t200)**2 / (2 * $sig**2));
            $ch += $gauss;
        }
        push @ch_data, $ch;
    }
    # pdl(\@ch_data) は [N_SAMP, N_CH] になるので transpose で [N_CH, N_SAMP] に
    pdl(\@ch_data)->float->transpose;
};

# ===========================================================================
# 1. Figure を先に作り、$fig->param / $fig->on_change でReactive に登録
# ===========================================================================
# NOTE: $fig->param() は Notebook 内なら Reactive に登録し既存値を返す。
#       スタンドアロン時は第2引数の既定値をそのまま返す（die しない）。

my $fig0 = figure(width => 900, height => 700);

my $gain     = $fig0->param('gain',   150,
    type => 'number', min => 10,  max => 1000, step => 10,
    label => "Gain (±μV)", group => 'eeg');

my $t_win_ms = $fig0->param('t_win', 1000,
    type => 'number', min => 100, max => int($T_SEC * 1000), step => 100,
    label => 'Window (ms)', group => 'eeg');

my $t0_ms    = $fig0->param('t0',       0,
    type => 'number', min => 0, max => int(($T_SEC - 0.1) * 1000), step => 50,
    label => 'Start (ms)', group => 'eeg');

# ===========================================================================
# 2. render クロージャ（LTTB 使用）
# ===========================================================================
# on_change から呼ばれる際は引数なし（Reactive::value()で最新値取得）。
# 初回描画時も同じクロージャを使う。
my $DISP_W = 900;   # 表示幅 px（Figure width に合わせる）

my $render = sub {
    # 最新パラメータを取得（Notebook: Reactive::value、スタンドアロン: クロージャ変数）
    my $g    = eval { require App::PDL::Notebook::Reactive;
                      App::PDL::Notebook::Reactive::value('gain') }    // $gain;
    my $twin = eval { App::PDL::Notebook::Reactive::value('t_win') }   // $t_win_ms;
    my $t0   = eval { App::PDL::Notebook::Reactive::value('t0') }      // $t0_ms;

    # 表示区間インデックス
    my $idx0 = int($t0             / 1000 * $SRATE);
    my $idx1 = int(($t0 + $twin)   / 1000 * $SRATE) - 1;
    $idx0 = 0          if $idx0 < 0;
    $idx1 = $N_SAMP-1  if $idx1 >= $N_SAMP;
    my $ns_view = $idx1 - $idx0 + 1;

    my $t_view  = $t_all->slice("$idx0:$idx1");

    # LTTB 目標点数: 表示幅×2（Nyquist-like）
    my $n_lttb = $DISP_W * 2;
    $n_lttb    = $ns_view if $n_lttb >= $ns_view;  # 間引き不要

    # Figure 生成（毎回新規: draw() idempotency 設計に従う）
    my $fig = figure(width => $DISP_W, height => 700);
    my @rows = $fig->subplots(5, 5);

    # ── チャンネル描画 ──
    my %used;
    for my $i (0 .. $N_CH - 1) {
        my ($r, $c, $name) = @{$LAYOUT[$i]}{qw(r c n)};
        $used{"$r,$c"} = 1;
        my $ax = $rows[$r][$c];

        my $y_full = $eeg->slice("($i),$idx0:$idx1")->squeeze;

        # LTTB 間引き
        my ($t_plot, $y_plot) = ($ns_view > $n_lttb)
            ? lttb($t_view->copy, $y_full->copy, $n_lttb)
            : ($t_view, $y_full);

        # ERP慣習: 負上（ylim max=+g が画面上端）
        $ax->line($t_plot, $y_plot, color => '#1a5276', lw => 0.9);
        $ax->xlim($t0, $t0 + $twin);
        $ax->ylim($g, -$g);      # 負上

        # ゼロライン
        $ax->hlines(0, color => '#aaaaaa', lw => 0.5);

        # チャンネル名（データ座標: 負上の「上端」= 負値側）
        $ax->text($t0 + $twin * 0.03, -$g * 0.72, $name,
            ha => 'left', va => 'top', fontsize => 7, color => '#2c3e50');

    }

    # ── 空パネル処理（used でない全マスを初期化）──
    for my $r (0..4) {
        for my $c (0..4) {
            next if $used{"$r,$c"};
            $rows[$r][$c]->xlim(0,1);
            $rows[$r][$c]->ylim(0,1);
        }
    }

    # ── 情報パネル（r=4, c=0）──
    {
        my $ax = $rows[4][0];
        $ax->text(0.5, 0.88, "EEG Demo (20ch)",
            ha => 'center', va => 'top', fontsize => 9, color => '#1a5276');
        $ax->text(0.05, 0.64, sprintf("Gain: \xB1%.0f \xB5V", $g),
            ha => 'left', va => 'top', fontsize => 9, color => '#2c3e50');
        $ax->text(0.05, 0.46, sprintf("Window: %.0f ms", $twin),
            ha => 'left', va => 'top', fontsize => 9, color => '#2c3e50');
        $ax->text(0.05, 0.28, sprintf("Start: %.0f ms", $t0),
            ha => 'left', va => 'top', fontsize => 9, color => '#2c3e50');
        my $pts_str   = ($ns_view > $n_lttb)
            ? sprintf("LTTB: %d->%d", $ns_view, $n_lttb)
            : sprintf("Full: %d pts", $ns_view);
        my $pts_color = ($ns_view > $n_lttb) ? '#27ae60' : '#7f8c8d';
        $ax->text(0.05, 0.10, $pts_str,
            ha => 'left', va => 'top', fontsize => 8, color => $pts_color);
    }

    # ── スケールバーパネル（r=4, c=4）──
    {
        my $ax = $rows[4][4];
        $ax->xlim($t0, $t0 + $twin);
        $ax->ylim($g, -$g);    # 負上（EEGパネルと同じ座標系）

        my $bar_ms = 100.0;
        my $bx0    = $t0 + $twin * 0.10;
        my $bx1    = $bx0 + $bar_ms;
        my $by     = $g * 0.55;   # 負上: 正値=画面上半分
        $ax->line(pdl($bx0,$bx1), pdl($by,$by),   color => '#2c3e50', lw => 2.0);
        $ax->line(pdl($bx0,$bx0), pdl($by-$g*0.06,$by+$g*0.06), color => '#2c3e50', lw => 1.5);
        $ax->line(pdl($bx1,$bx1), pdl($by-$g*0.06,$by+$g*0.06), color => '#2c3e50', lw => 1.5);
        $ax->text(($bx0+$bx1)/2, $by - $g*0.18, "100 ms",
            ha => 'center', va => 'bottom', fontsize => 7, color => '#2c3e50');

        my $sv  = $g * 0.5;
        my $svx = $t0 + $twin * 0.70;
        $ax->line(pdl($svx,$svx), pdl($sv/2,-$sv/2), color => '#2c3e50', lw => 2.0);
        $ax->line(pdl($svx-$twin*0.04,$svx+$twin*0.04), pdl($sv/2,$sv/2), color => '#2c3e50', lw => 1.5);
        $ax->line(pdl($svx-$twin*0.04,$svx+$twin*0.04), pdl(-$sv/2,-$sv/2), color => '#2c3e50', lw => 1.5);
        $ax->text($svx+$twin*0.06, 0.0, sprintf("%.0f uV", $sv),
            ha => 'left', va => 'center', fontsize => 7, color => '#2c3e50');
        $ax->text($t0+$twin*0.5, $g*0.78, "Scale",
            ha => 'center', va => 'bottom', fontsize => 7, color => '#7f8c8d');
    }

    $fig->tight_layout(pad => 1.05, h_pad => 8, w_pad => 8, uniform_margins => 1);

    # Notebook 内（PDLNB_INLINE 環境変数が立っている場合）: Display::QUEUE に積む
    if ($ENV{PDLNB_INLINE}) {
        require App::PDL::Notebook::Display;
        my ($mime, $data) = $fig->to_inline;
        if ($mime eq 'image/png') {
            App::PDL::Notebook::Display::publish_png($data);
        } else {
            App::PDL::Notebook::Display::publish_svg($data);
        }
    }

    return $fig;
};

# ===========================================================================
# 3. on_change 登録（Notebook 内のみ有効; スタンドアロンは no-op）
# ===========================================================================
$fig0->on_change($render, 'eeg');

# ===========================================================================
# 4. 初回描画
# ===========================================================================
my $fig = $render->();

# スタンドアロン: PNG に保存して確認
# Notebook 内（PDLNB_INLINE 環境変数あり）: $render 内で publish 済み
unless ($ENV{PDLNB_INLINE}) {
    my $out = 'notebook_eeg_demo_out.png';
    $fig->save($out);
    print "saved: $out\n";
}

__END__

=head1 NAME

notebook_eeg_demo.pl - App-PDL-Notebook 向け EEG ビューア（LTTB統合）

=head1 SYNOPSIS

  # Notebook セル内
  do 'examples/notebook_eeg_demo.pl';

  # スタンドアロン確認
  perl examples/notebook_eeg_demo.pl   # → notebook_eeg_demo_out.png

=head1 DESCRIPTION

20チャンネル EEG を国際10-20法の 5×5 グリッドに表示する
App-PDL-Notebook 向けデモ。

=head2 高速化

=over 4

=item 1. C<on_change> でクロージャ粒度の再実行

C<< $fig->on_change($render, 'eeg') >> により、スライダ更新時は
C<$render> クロージャのみ再実行（セル全体の再評価なし）。
カーネルは C<{type=>'event'}> を受信すると C<Reactive::handle_event> →
C<Display::QUEUE> を drain するだけ。

=item 2. C<PDL::Graphics::Cairo::LTTB>

C<lttb($t, $y, $DISP_W * 2)> で表示幅×2点に間引く（約80%削減）。
スパイク（EOGアーティファクト等）は三角形面積最大化により保持。

=back

=head2 パラメータ

  gain     10〜500 μV   既定150: 縦軸スケール
  t_win   100〜3000 ms  既定1000: 時間窓幅
  t0        0〜2900 ms  既定0: 表示開始時刻

=head2 実データへの差し替え

  use PDL::EEG::IO::NihonKohden;
  my ($eeg, $meta) = read_nk('YJ0394VB.EEG', all_blocks => 1);
  # $eeg: [N_CH, N_SAMP] float32 μV

=head1 SEE ALSO

L<PDL::Graphics::Cairo>, L<PDL::Graphics::Cairo::LTTB>, L<App::PDL::Notebook>

=cut
