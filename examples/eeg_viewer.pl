#!/usr/bin/env perl
# eeg_viewer.pl — 20チャンネルEEGビューア（LTTB統合版）
#
# 段階C: LTTBをEEGビューアに組み込み
#   - 表示時: LTTB間引き（窓幅×2点）でスライダ追従を高速化
#   - 保存時: フル解像度（is_save=1 時にrenderに渡されるoptで判断）
#   - スライダ0: gain (50〜500 μV), スライダ1: 時間窓 (100〜1000 ms)
#
# 使い方:
#   perl examples/eeg_viewer.pl [EEGファイル.dat]
#   （引数なし → 合成デモデータで起動）
#
# ファイル形式（引数あり）:
#   バイナリfloat32、[n_ch × n_samples]、行優先（C順）
#   先頭2行: n_ch, n_samples（テキスト行）
#
# レイアウト: 10-20国際配置 5×5グリッド（20ch）
#   Fp1 Fp2  -   -   -
#   F7  F3  Fz  F4  F8
#   T3  C3  Cz  C4  T4
#   T5  P3  Pz  P4  T6
#   O1  [値テキスト]  O2
#
# キー: マウス移動で座標表示、クリックでスパイク時刻ピック

use strict;
use warnings;
use PDL;
use PDL::Graphics::Cairo qw(figure);
use PDL::Graphics::Cairo::Driver::GS;
use PDL::Graphics::Cairo::LTTB qw(lttb);

# ─── 1. チャンネル配置（10-20 国際配置、ERP 実験でよく使う20ch）───
# グリッド上の (行, 列) インデックス（0始まり）
# 空きマスは undef
my @LAYOUT = (
    # row 0: Fp1/Fp2 を F3/F4 の真上に配置（10-20配置準拠）
    { r=>0, c=>1, name=>'Fp1' },
    { r=>0, c=>3, name=>'Fp2' },
    # row 1
    { r=>1, c=>0, name=>'F7'  },
    { r=>1, c=>1, name=>'F3'  },
    { r=>1, c=>2, name=>'Fz'  },
    { r=>1, c=>3, name=>'F4'  },
    { r=>1, c=>4, name=>'F8'  },
    # row 2
    { r=>2, c=>0, name=>'T3'  },
    { r=>2, c=>1, name=>'C3'  },
    { r=>2, c=>2, name=>'Cz'  },
    { r=>2, c=>3, name=>'C4'  },
    { r=>2, c=>4, name=>'T4'  },
    # row 3
    { r=>3, c=>0, name=>'T5'  },
    { r=>3, c=>1, name=>'P3'  },
    { r=>3, c=>2, name=>'Pz'  },
    { r=>3, c=>3, name=>'P4'  },
    { r=>3, c=>4, name=>'T6'  },
    # row 4: O1/O2 を P3/P4 の真下に（情報パネルは c=0,2,4）
    { r=>4, c=>1, name=>'O1'  },
    { r=>4, c=>3, name=>'O2'  },
);
# 情報パネル: r=4, c=0,2,4
my $N_CH = scalar @LAYOUT;   # 20

# 情報パネル位置
my $INFO_R = 4; my @INFO_C = (0,2,4);  # O1/O2 が c=1,3 に移動したので

# ─── 2. データ生成 or 読み込み ───────────────────────────────────────
my ($eeg, $srate, $n_samples);

if (@ARGV && -f $ARGV[0]) {
    # 外部ファイル読み込み（float32 binary, 先頭2行: n_ch, n_samples）
    open my $fh, '<', $ARGV[0] or die "Cannot open $ARGV[0]: $!";
    my $nc   = int(<$fh>);
    my $ns   = int(<$fh>);
    my $raw  = '';
    read $fh, $raw, $nc * $ns * 4;
    close $fh;
    $eeg      = pdl(float, [unpack("f*", $raw)])->reshape($nc, $ns);
    $srate    = 1000;    # デフォルト 1kHz
    $n_samples = $ns;
    warn "Loaded: ${nc}ch × ${ns}samples\n";
} else {
    # ─ 合成デモデータ: 20ch × 2000 samples (2s @ 1kHz) ─
    $srate    = 1000;
    $n_samples = 2000;

    # ベースEEG: 1/fノイズ近似 = ランダム + ローパス風
    my @channels;
    srand(42);
    for my $i (0 .. $N_CH - 1) {
        # ピンクノイズ近似: ランダムウォーク + 低周波成分
        my $noise  = grandom($n_samples) * 15;            # μV
        my $alpha  = sin(sequence($n_samples) * (2*3.14159*10/$srate)) * 20;  # 10Hz alpha
        my $theta  = sin(sequence($n_samples) * (2*3.14159*6/$srate) + $i*0.3) * 8;   # 6Hz theta
        # ERP: N200 @ 200ms, P300 @ 300ms （後頭部優位）
        my $t_ms   = sequence($n_samples) * (1000/$srate);
        my $n200   = -30 * exp(-(($t_ms - 200)**2) / (2 * 30**2));
        my $p300   = 40  * exp(-(($t_ms - 300)**2) / (2 * 50**2));
        my $erp_weight = ($i >= 12 && $i <= 16) ? 1.0 : 0.3;  # 頭頂後頭部優位
        # EOGアーティファクト: ch0,1（Fp1,Fp2）にスパイク
        my $spike  = zeros($n_samples);
        if ($i <= 1) {
            my $sp = int($n_samples * 0.6);
            my $sp_width = pdl(30);
            my $sp_range = sequence(60) - 30;
            $spike->slice("${sp}:" . ($sp+29)) .= 150 * exp(-($sp_range->slice("0:29")**2) / 50);
        }
        push @channels, $noise + $alpha + $theta + ($n200 + $p300) * $erp_weight + $spike;
    }
    $eeg = pdl(\@channels)->xchg(0,1);  # [N_CH, n_samples]
    warn "Demo data: ${N_CH}ch × ${n_samples}samples @ ${srate}Hz\n";
}

# 時刻軸（ms）
my $t_full = sequence($n_samples) * (1000.0 / $srate);   # 0..2000ms

# ─── 3. スライダ設定 ─────────────────────────────────────────────────
# スライダ0: gain (50〜500μV/グリッド)
# スライダ1: 表示時間窓（右端 ms; 最低100ms）
my %INIT_STATE = (
    0  => 0.2,      # 時間窓スライダ（水平, 0..1 → 100..2000ms）
    1  => 0.5,      # gain スライダ（垂直, 0..1 → 50..500μV）
);

# スライダ値 → 実際のパラメータへの変換
sub gain_from_state  { my $v = $_[0]{1} // 0.5; 50 + $v * 450 }   # 垂直(1): 50..500 μV
sub tmax_from_state  { my $v = $_[0]{0} // 0.2; 100 + $v * ($n_samples * 1000.0/$srate - 100) }  # 水平(0)

# ─── 4. LTTB ヘルパー ────────────────────────────────────────────────
# 表示幅から最適な出力点数を決める（1px あたり最大2点）
sub n_out_for_width { my $w = $_[0]; int($w / 5 * 2) || 200 }   # /5: 5列

# ─── 5. render コールバック ──────────────────────────────────────────
my $render = sub {
    my ($state, $w, $h, $opts) = @_;
    $opts //= {};
    my $is_save = $opts->{is_save} // 0;

    # パラメータ取得
    my $gain     = gain_from_state($state);    # μV
    my $tmax_ms  = tmax_from_state($state);    # ms（表示右端）

    # 表示する時刻範囲
    my $t0  = 0.0;
    my $t1  = $tmax_ms;
    my $idx0 = 0;
    my $idx1 = int($tmax_ms / 1000.0 * $srate);
    $idx1 = $n_samples - 1 if $idx1 >= $n_samples;

    # 表示用 t 軸
    my $t_view = $t_full->slice("$idx0:$idx1");
    my $ns_view = $t_view->nelem;

    # LTTB 点数（保存時はフル解像度）
    my $n_lttb = $is_save ? $ns_view : n_out_for_width($w);
    $n_lttb = $ns_view if $n_lttb >= $ns_view;

    # Figure 生成（5×5 グリッド）
    my $fig = figure(width => $w, height => $h);

    # 下段パネルを少し低く（80%）
    # 均一グリッドで近似（GridSpec の height_ratios は将来対応）
    my @rows = $fig->subplots(5, 5);

    # デフォルトで全パネルを非表示化（軸なし）
    for my $r (0..4) {
        for my $c (0..4) {
            $rows[$r][$c]->xlim(0, 1);
            $rows[$r][$c]->ylim(0, 1);
        }
    }

    # ─ チャンネル描画 ─
    my $y_center = 0.0;
    my $y_half   = $gain;    # ±gain μV

    for my $ch_idx (0 .. $#LAYOUT) {
        my $ch   = $LAYOUT[$ch_idx];
        my ($r, $c, $name) = @{$ch}{qw(r c name)};
        my $ax = $rows[$r][$c];

        # channel data
        my $y_full = $eeg->slice("($ch_idx),$idx0:$idx1");

        # LTTB 間引き（保存時はスキップ）
        my ($t_plot, $y_plot);
        if ($n_lttb < $ns_view) {
            ($t_plot, $y_plot) = lttb($t_view, $y_full, $n_lttb);
        } else {
            ($t_plot, $y_plot) = ($t_view, $y_full);
        }

        # ERP 慣習: 負上（y軸を反転）
        $ax->line($t_plot, $y_plot,
            color => '#1a5276', lw => 1.0);
        $ax->xlim($t0, $t1);
        $ax->ylim($y_half, -$y_half);   # 負上: max=+gain(上) min=-gain(下)
        $ax->axhline(0.0, color => '#aaa', lw => 0.5);  # zero line

        # チャンネル名ラベル（左上、データ座標 = xlim/ylim の左上付近）
        # チャンネル名: 左端付近、負上の「上端」= -y_half 側（画面上）
        my $label_x = $t0 + ($t1 - $t0) * 0.02;
        my $label_y = -$y_half * 0.72;   # 負値=画面上端、枠から内側
        $ax->text($label_x, $label_y, $name,
            ha => 'left', va => 'top',
            fontsize => 7, color => '#1a3a5c');

        # 時刻軸ラベルは最下行だけ
    }

    # ─ 情報パネル（r=4, c=1,2,3） — 軸を 0..1 で使用 ─
    {
        my $ax = $rows[$INFO_R][0];
        $ax->xlim(0,1); $ax->ylim(0,1);
        $ax->text(0.5, 0.82, "EEG Viewer",
            ha => 'center', va => 'top',
            fontsize => 10, color => '#1a5276');
        $ax->text(0.05, 0.58, "Gain: \xB1" . sprintf("%.0f", $gain) . " \xB5V",
            ha => 'left', va => 'top', fontsize => 9, color => '#2c3e50');
        $ax->text(0.05, 0.40, "Window: " . sprintf("%.0f", $tmax_ms) . " ms",
            ha => 'left', va => 'top', fontsize => 9, color => '#2c3e50');
        my $pts_str = ($n_lttb < $ns_view)
            ? sprintf("LTTB: %d->%d", $ns_view, $n_lttb)
            : sprintf("Full: %d pts", $ns_view);
        $ax->text(0.05, 0.22, $pts_str,
            ha => 'left', va => 'top', fontsize => 8,
            color => ($n_lttb < $ns_view ? '#27ae60' : '#7f8c8d'));
    }

    # ─ cursor_overlay: カーソル座標表示 ─
    if (defined $state->{_cursor_x}) {
        my $cx     = $state->{_cursor_x};   # 時刻 (ms) — これだけ使う
        my $type   = $state->{_cursor_type} // 'cursor';
        my $color  = ($type eq 'pick') ? '#c0392b' : '#16a085';

        # カーソル時刻に最も近いサンプルインデックスを求める
        my $t_idx = ($t_view - $cx)->abs->minimum_ind->sclr;
        my $t_snap = $t_view->at($t_idx);   # スナップした実際の時刻

        # どのチャンネルパネルにマウスがあるかを特定
        # axes_list は subplots(5,5) の順（行優先）で 25 エントリ
        # @LAYOUT の ch_idx → axes_list インデックスのマッピングを構築
        # subplots(5,5): axes_list[$r*5+$c] がパネル(r,c)に対応
        my $ax_idx    = $state->{_cursor_ax_idx} // -1;
        my $hit_ch_idx = -1;
        if ($ax_idx >= 0) {
            for my $ci (0 .. $#LAYOUT) {
                my ($r, $c) = @{$LAYOUT[$ci]}{qw(r c)};
                if ($r * 5 + $c == $ax_idx) { $hit_ch_idx = $ci; last }
            }
        }

        # ヒットチャンネルのデータ値（時刻補間）
        my $data_v = undef;
        my $hit_name = undef;
        if ($hit_ch_idx >= 0) {
            my $y_ch  = $eeg->slice("($hit_ch_idx),$idx0:$idx1");
            $data_v   = $y_ch->at($t_idx);
            $hit_name = $LAYOUT[$hit_ch_idx]{name};
        }

        # 情報パネル中央列に表示
        my $ax_info = $rows[$INFO_R][2];  # 中央
        $ax_info->xlim(0,1); $ax_info->ylim(0,1);
        $ax_info->text(0.5, 0.90,
            ($type eq 'pick' ? 'PICK' : 'Cursor'),
            ha => 'center', va => 'top', fontsize => 9, color => $color);
        $ax_info->text(0.5, 0.72,
            sprintf("t = %.1f ms", $t_snap),
            ha => 'center', va => 'top', fontsize => 9, color => $color);
        if (defined $data_v) {
            $ax_info->text(0.5, 0.54,
                sprintf("v = %.1f uV", $data_v),
                ha => 'center', va => 'top', fontsize => 9, color => $color);
            $ax_info->text(0.5, 0.36,
                "ch: $hit_name",
                ha => 'center', va => 'top', fontsize => 8, color => $color);
        }

        # 全チャンネルに縦線（カーソル時刻）を描く
        for my $ch (@LAYOUT) {
            my ($r, $c) = @{$ch}{qw(r c)};
            $rows[$r][$c]->axvline($t_snap, color => $color, lw => 0.8, ls => '--');
        }

        # PICK: ヒットチャンネルにデータ点をハイライト
        if ($type eq 'pick' && $hit_ch_idx >= 0) {
            my $ch      = $LAYOUT[$hit_ch_idx];
            my $y_ch    = $eeg->slice("($hit_ch_idx),$idx0:$idx1");
            my $ax_pick = $rows[$ch->{r}][$ch->{c}];
            $ax_pick->scatter(
                pdl($t_snap),
                pdl($y_ch->at($t_idx)),
                color => '#c0392b', s => 40);
        }
    }

    # - Scale bar (r=4, c=4): EEGと同じxlim/ylim(負上)で描画 -
    {
        my $ax = $rows[4][4];
        # EEGパネルと同じ座標系（負上）
        $ax->xlim($t0, $t1);
        $ax->ylim($y_half, -$y_half);   # 負上

        # 水平スケールバー: 100ms、y=+gain*0.6付近（負上なので画面上半分）
        my $bar_ms  = 100.0;
        my $bx0 = $t0 + ($t1 - $t0) * 0.10;
        my $bx1 = $bx0 + $bar_ms;
        my $by  = $y_half * 0.55;   # 負上: 正値=上
        $ax->line(pdl($bx0, $bx1), pdl($by,  $by),  color => '#2c3e50', lw => 2.0);
        $ax->line(pdl($bx0, $bx0), pdl($by - $y_half*0.06, $by + $y_half*0.06),
            color => '#2c3e50', lw => 1.5);
        $ax->line(pdl($bx1, $bx1), pdl($by - $y_half*0.06, $by + $y_half*0.06),
            color => '#2c3e50', lw => 1.5);
        $ax->text(($bx0+$bx1)/2, $by - $y_half*0.18, "100 ms",
            ha => 'center', va => 'bottom', fontsize => 7, color => '#2c3e50');

        # 垂直スケールバー: gain/2 uV、EEG実データ座標で正確に描画
        my $sv    = $y_half * 0.5;   # gain/2 uV
        my $svx   = $t0 + ($t1 - $t0) * 0.70;
        my $svy0  = $sv / 2;    # 正値（負上で画面上）
        my $svy1  = -$sv / 2;   # 負値（負上で画面下）
        $ax->line(pdl($svx, $svx), pdl($svy0, $svy1), color => '#2c3e50', lw => 2.0);
        $ax->line(pdl($svx - ($t1-$t0)*0.04, $svx + ($t1-$t0)*0.04),
            pdl($svy0, $svy0), color => '#2c3e50', lw => 1.5);
        $ax->line(pdl($svx - ($t1-$t0)*0.04, $svx + ($t1-$t0)*0.04),
            pdl($svy1, $svy1), color => '#2c3e50', lw => 1.5);
        $ax->text($svx + ($t1-$t0)*0.06, 0.0,
            sprintf("%.0f uV", $sv),
            ha => 'left', va => 'center', fontsize => 7, color => '#2c3e50');

        # ラベル
        $ax->text($t0 + ($t1-$t0)*0.5, $y_half * 0.75, "Scale",
            ha => 'center', va => 'bottom', fontsize => 7, color => '#7f8c8d');
    }

    $fig->tight_layout(pad => 1.05, h_pad => 8, w_pad => 8, uniform_margins => 1);
    return $fig;
};

# ─── 6. giza-server 起動 ─────────────────────────────────────────────
my $drv = PDL::Graphics::Cairo::Driver::GS->new(
    width  => 1000,
    height => 700,
    title  => 'EEG Viewer — LTTB統合版',
);

printf "EEG Viewer 起動\n";
printf "  チャンネル数: %d, サンプル数: %d, サンプリング率: %d Hz\n",
    $N_CH, $n_samples, $srate;
printf "  スライダ0 (垂直): Gain 50..500 μV\n";
printf "  スライダ1 (水平): 時間窓 100..%.0f ms\n", $n_samples * 1000.0 / $srate;
printf "  マウス移動: カーソル座標表示\n";
printf "  クリック: 最近傍点ピック\n\n";

$drv->show_interactive(
    init           => \%INIT_STATE,
    render         => $render,
    cursor_overlay => 1,
    on_cursor => sub {
        my ($fx, $fy) = @_;
        # ターミナルへの出力は最小限（デバッグ用）
        # printf "\r  cursor frac=(%.3f, %.3f)", $fx, $fy;
    },
    on_pick => sub {
        my ($fx, $fy, $btn) = @_;
        printf "\nPICK btn=%d frac=(%.3f, %.3f)\n", $btn, $fx, $fy;
    },
);
