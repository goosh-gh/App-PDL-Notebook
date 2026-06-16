#!/usr/bin/env perl
# examples/notebook_eeg_raw.pl — App-PDL-Notebook: MNE raw.plot()-style EEG viewer
#
# Usage:
#   # Inside an App-PDL-Notebook cell:
#   do 'examples/notebook_eeg_raw.pl';
#
#   # Standalone (PNG check):
#   perl examples/notebook_eeg_raw.pl [file.EEG] [--block=N]
#   # → notebook_eeg_raw_out.png
#
# How it works:
#   - param/on_change bridge: browser sliders -> Reactive::handle_event
#     -> $render closure -> to_inline PNG -> WebSocket -> browser
#   - $render is identical in structure to eeg_viewer_raw.pl (same %state keys),
#     but outputs PNG via to_inline instead of giza-server
#   - LTTB downsampling keeps render time low even for large files
#
# Dependencies:
#   PDL::Graphics::Cairo + LTTB  (goosh-gh/PDL-Graphics-Cairo)
#   App::PDL::Notebook            (goosh-gh/App-PDL-Notebook)  -- Notebook only
#   PDL::EEG::IO::NihonKohden     (goosh-gh/PDL-EEG)          -- real data only

use strict;
use warnings;
no warnings 'redefine';
use PDL;
use PDL::Graphics::Cairo qw(figure);
use PDL::Graphics::Cairo::LTTB qw(lttb_minmax);

# ═══════════════════════════════════════════════════════════════════════
# User settings
# ═══════════════════════════════════════════════════════════════════════
my $N_ROWS_VIS    = 8;      # number of waveform rows visible at once
my $PAGE_SEC_INIT = 10.0;   # initial time window (seconds)
my $FIG_W         = 900;    # figure width (pixels)
my $FIG_H         = 620;    # figure height (pixels)

# ═══════════════════════════════════════════════════════════════════════
# 1. Data loading / generation
# ═══════════════════════════════════════════════════════════════════════

my ($eeg, $srate, $n_samples, @CH_NAMES);

# --- Real data: Nihon Kohden .EEG ---
if (@ARGV && -f $ARGV[0] && $ARGV[0] =~ /\.eeg$/i) {
    eval { require PDL::EEG::IO::NihonKohden } or die "PDL::EEG::IO::NihonKohden required: $@\n";
    PDL::EEG::IO::NihonKohden->import('read_nk');

    my $eeg_file = shift @ARGV;
    my @block_list;
    for my $arg (@ARGV) {
        if    ($arg =~ /^--block=(\d+)$/)     { @block_list = (int($1)) }
        elsif ($arg =~ /^--blocks=([\d,]+)$/) { @block_list = map { int($_) } split /,/, $1 }
    }

    my $rec0     = read_nk($eeg_file, block => 0);
    my $n_blocks = $rec0->{n_blocks} // 1;
    @block_list = (0 .. $n_blocks - 1) unless @block_list;
    @block_list = grep { $_ < $n_blocks } @block_list;

    warn sprintf("  blocks: [%s] / %d total\n", join(', ', @block_list), $n_blocks);

    my @blocks;
    for my $b (@block_list) {
        my $rec = ($b == 0) ? $rec0 : read_nk($eeg_file, block => $b);
        push @blocks, $rec->{data};
    }
    $eeg      = @blocks == 1 ? $blocks[0] : PDL::glue(1, @blocks);
    $srate    = $rec0->{fs};
    @CH_NAMES = grep { $_ ne 'PAD' } @{ $rec0->{labels} };
    my $n_ch_valid = scalar @CH_NAMES;
    $eeg = $eeg->slice("0:@{[$n_ch_valid-1]},:");
    $n_samples = $eeg->dim(1);
    warn sprintf("Loaded: %dch x %d samples @ %d Hz (%.1f s)\n",
        $n_ch_valid, $n_samples, $srate, $n_samples/$srate);

# --- Demo mode: synthetic 34-channel x 30 s ---
} else {
    $srate     = 1000;
    $n_samples = 30 * $srate;
    @CH_NAMES  = qw(
        Fp1 Fp2 F7  F3  Fz  F4  F8
        T3  C3  Cz  C4  T4
        T5  P3  Pz  P4  T6
        O1  O2
        A1  A2
        F9  F10 T9  T10 P9  P10
        Fpz FCz CPz POz Oz
        EKG EMG
    );
    my $N = scalar @CH_NAMES;
    my @channels;
    srand(42);
    for my $i (0 .. $N-1) {
        my $noise = grandom($n_samples) * 15;
        my $alpha = sin(sequence($n_samples) * (2*3.14159*10/$srate) + $i*0.5) * 20;
        my $theta = sin(sequence($n_samples) * (2*3.14159*6 /$srate) + $i*0.3) * 8;
        my $erp   = zeros($n_samples);
        for my $rep (0..5) {
            my $t0r = ($rep * 5 + 1) * $srate;
            my $dt  = (sequence($n_samples) - $t0r) * (1000.0/$srate);
            $erp += (-25 * exp(-($dt**2)/(2*30**2))
                   +  35 * exp(-(($dt-100)**2)/(2*50**2)))
                   * (($i >= 12 && $i <= 18) ? 1.0 : 0.25);
        }
        my $art = zeros($n_samples);
        if ($i <= 1) {
            for my $t (map { int($_ * $srate) } (3, 8, 15, 22, 27)) {
                my $dt2 = sequence($n_samples) - $t;
                $art += 180 * exp(-($dt2**2)/(2*200**2));
            }
        }
        if ($CH_NAMES[$i] eq 'EKG') {
            my $rr = int($srate * 60.0 / 72);
            for (my $t = 0; $t < $n_samples; $t += $rr) {
                my $dt2 = sequence($n_samples) - $t;
                $art += 300 * exp(-($dt2**2)/(2*5**2));
            }
            $noise *= 0.3;
        }
        push @channels, $noise + $alpha + $theta + $erp + $art;
    }
    $eeg = pdl(\@channels)->xchg(0,1);
    warn sprintf("Demo: %dch x %.0fs @ %dHz\n", $N, $n_samples/$srate, $srate);
}

my $N_CH_ALL = scalar @CH_NAMES;
$N_ROWS_VIS  = $N_CH_ALL if $N_ROWS_VIS > $N_CH_ALL;
my $t_full   = sequence($n_samples) * (1000.0 / $srate);  # ms
my $DATA_MS  = $n_samples * 1000.0 / $srate;

# ═══════════════════════════════════════════════════════════════════════
# 2. State helpers (same as eeg_viewer_raw.pl)
# ═══════════════════════════════════════════════════════════════════════

my @GAIN_STEPS = (10, 20, 50, 100, 150, 200, 300, 500, 1000);

sub _page_ms         { $_[0]{_page_ms} // ($PAGE_SEC_INIT * 1000.0) }
sub _gain_from_state { $_[0]{_gain}    // 100.0 }
sub _ch_off_from_state {
    my $idx = $_[0]{_ch_off} // 0;
    my $max = $N_CH_ALL - $N_ROWS_VIS; $max = 0 if $max < 0;
    $idx = 0 if $idx < 0; $idx = $max if $idx > $max;
    return $idx;
}
sub _tstart_from_state {
    my $max = $DATA_MS - _page_ms($_[0]); $max = 0 if $max < 0;
    ($_[0]{_pos} // 0.0) * $max;
}

# ═══════════════════════════════════════════════════════════════════════
# 3. Notebook params
#    %state keys map 1:1 to Reactive params
#    In standalone mode, param() returns the default value directly
# ═══════════════════════════════════════════════════════════════════════

# Lazy loader for Reactive (no-op in standalone)
sub _param {
    my ($name, $default, %opt) = @_;
    my $v = eval {
        require App::PDL::Notebook::Reactive;
        App::PDL::Notebook::Reactive::param($name, $default, %opt);
    };
    return defined $v ? $v : $default;
}
sub _value {
    my ($name, $default) = @_;
    my $v = eval { App::PDL::Notebook::Reactive::value($name) };
    return defined $v ? $v : $default;
}

eval { App::PDL::Notebook::Reactive::reset() }; ## every 'do' clears parameters !

# Declare params (only takes effect inside Notebook)
my $n_pages = int($DATA_MS / ($PAGE_SEC_INIT * 1000.0)) || 1;
_param('_pos',     0.0,                type=>'number', min=>0.0,        max=>1.0,
    step=>0.001, label=>'Position',    group=>'eeg');
_param('_page_ms', $PAGE_SEC_INIT*1e3, type=>'number', min=>1000,       max=>$DATA_MS,
    step=>1000,  label=>'Window (ms)', group=>'eeg');
_param('_gain',    100.0,              type=>'enum',   options=>\@GAIN_STEPS,
     label=>"Gain (\xB5V)",             group=>'eeg');
_param('_ch_off',  0,                  type=>'number', min=>0,
    max=>($N_CH_ALL - $N_ROWS_VIS > 0 ? $N_CH_ALL - $N_ROWS_VIS : 0),
    step=>1,     label=>'Ch offset',   group=>'eeg');
_param('_neg_up',  1,                  type=>'bool',   label=>'Neg-up', group=>'eeg');

# ═══════════════════════════════════════════════════════════════════════
# 4. render callback
#    Reads current param values from Reactive (or defaults in standalone)
#    Returns $fig; also publishes to Display queue when PDLNB_INLINE is set
# ═══════════════════════════════════════════════════════════════════════

my $render = sub {
    # Build %state from current Reactive values
    my %state = (
        _pos     => _value('_pos',     0.0),
        _page_ms => _value('_page_ms', $PAGE_SEC_INIT * 1000.0),
        _gain    => _value('_gain',    100.0),
        _ch_off  => _value('_ch_off',  0),
        _neg_up  => _value('_neg_up',  1),
    );

    my $gain    = _gain_from_state(\%state);
    my $page_ms = _page_ms(\%state);
    my $t_start = _tstart_from_state(\%state);
    my $t_end   = $t_start + $page_ms;
    $t_end      = $DATA_MS if $t_end > $DATA_MS;
    my $ch_off  = _ch_off_from_state(\%state);
    my $neg_up  = $state{_neg_up} // 1;

    my $idx0 = int($t_start / 1000.0 * $srate);
    my $idx1 = int($t_end   / 1000.0 * $srate) - 1;
    $idx0 = 0              if $idx0 < 0;
    $idx0 = $n_samples - 1 if $idx0 >= $n_samples;
    $idx1 = $n_samples - 1 if $idx1 >= $n_samples;
    $idx1 = $idx0          if $idx1 < $idx0;

    my $t_view  = $t_full->slice("$idx0:$idx1");
    my $ns_view = $t_view->nelem;

    # LTTB: target = FIG_W pts (1px per point)
    my $n_lttb = $FIG_W;
    $n_lttb    = $ns_view if $n_lttb >= $ns_view;

    # Build figure
    my $fig = figure(width => $FIG_W, height => $FIG_H);

    # GridSpec: N_ROWS_VIS waveform rows + 1 info row (fixed small height)
    my $info_ratio = 0.18;   # info row is 18% of one waveform row height
    my @ratios = ((1) x $N_ROWS_VIS, $info_ratio);
    my $gs = $fig->add_gridspec($N_ROWS_VIS + 1, 1,
        height_ratios => \@ratios, hspace => 0.0);

    my @axes;
    push @axes, $fig->add_subplot($gs->at($_, 0)) for 0 .. $N_ROWS_VIS - 1;
    my $ax_info = $fig->add_subplot($gs->at($N_ROWS_VIS, 0));

    # ── Waveform channels ────────────────────────────────────────────
    my $ml = 48; my $mr = 8;
    for my $row (0 .. $N_ROWS_VIS - 1) {
        my $ch_idx = $ch_off + $row;
        last if $ch_idx >= $N_CH_ALL;
        my $ax     = $axes[$row];
        my $y_full = $eeg->slice("($ch_idx),$idx0:$idx1");
        my ($t_plot, $y_plot);
        if ($n_lttb < $ns_view) {
            ($t_plot, $y_plot) = lttb_minmax($t_view, $y_full, $n_lttb);
        } else {
            ($t_plot, $y_plot) = ($t_view, $y_full);
        }
        $ax->line($t_plot, $y_plot, color => '#1a5276', lw => 0.8);
        $ax->xlim($t_start, $t_end);
        $ax->ylim($neg_up ? ($gain, -$gain) : (-$gain, $gain));
        $ax->tick_params(axis => 'x', labelbottom => 0, length => 0);
        $ax->tick_params(axis => 'y', labelleft   => 0, length => 0);
        $ax->ylabel($CH_NAMES[$ch_idx]);
        $ax->ylabel_rotation(0);
        $ax->margin_left($ml); $ax->margin_right($mr);
        $ax->margin_top(2);    $ax->margin_bottom(2);
    }

    # ── Info bar (bottom) ────────────────────────────────────────────
    {
        $ax_info->xlim(0, 1); $ax_info->ylim(0, 1);
        $ax_info->axis('off');

        my $t_end_s   = ($t_start + $page_ms) / 1000.0;
        my $t_start_s = $t_start / 1000.0;
        my $ch_max    = $N_CH_ALL - $N_ROWS_VIS;
        my $ch_str    = $ch_max > 0
            ? sprintf("ch %d-%d / %d", $ch_off+1, $ch_off+$N_ROWS_VIS, $N_CH_ALL)
            : sprintf("%d ch", $N_CH_ALL);

        # Time range (left)
        $ax_info->text(0.01, 0.75,
            sprintf("%.1f-%.1fs  |  %s  |  \xB1%.0f\xB5V  |  %s",
                $t_start_s, $t_end_s, $ch_str, $gain,
                $neg_up ? "neg\x{2191}" : "pos\x{2191}"),
            ha => 'left', va => 'center', fontsize => 8, color => '#2c3e50');

        # LTTB info (right)
        my $lttb_str = ($n_lttb < $ns_view)
            ? sprintf("LTTB: %d\x{2192}%d/ch", $ns_view, $n_lttb)
            : sprintf("Full: %d pts/ch", $ns_view);
        $ax_info->text(0.99, 0.75, $lttb_str,
            ha => 'right', va => 'center', fontsize => 8,
            color => ($n_lttb < $ns_view ? '#27ae60' : '#888888'));

        $ax_info->margin_left($ml); $ax_info->margin_right($mr);
        $ax_info->margin_top(0);    $ax_info->margin_bottom(2);
    }

    $fig->{_tight_done} = 1;

    # Publish to Notebook display queue
    if ($ENV{PDLNB_INLINE}) {
        require App::PDL::Notebook::Display;
        my ($mime, $data) = $fig->to_inline;
        App::PDL::Notebook::Display::publish_png($data)  if $mime eq 'image/png';
        App::PDL::Notebook::Display::publish_svg($data)  if $mime eq 'image/svg+xml';
    }

    return $fig;
};

# ═══════════════════════════════════════════════════════════════════════
# 5. Register on_change and do initial render
# ═══════════════════════════════════════════════════════════════════════

eval {
    require App::PDL::Notebook::Reactive;
    App::PDL::Notebook::Reactive::on_change($render, 'eeg');
    1;
};

# Initial render
my $fig = $render->();

# Standalone: save PNG for inspection
unless ($ENV{PDLNB_INLINE}) {
    my $out = 'notebook_eeg_raw_out.png';
    $fig->save($out);
    print "saved: $out\n";

    # Timing benchmark (requires Time::HiRes for sub-second resolution)
    require Time::HiRes;
    $render->();   # warmup
    my $N = 10;
    my $t0 = Time::HiRes::time();
    $render->() for 1 .. $N;
    my $avg_ms = (Time::HiRes::time() - $t0) * 1000 / $N;
    printf "avg render: %.1f ms/frame (N_ROWS_VIS=%d, n_lttb=%d, N_CH=%d)\n",
        $avg_ms, $N_ROWS_VIS, $FIG_W, $N_CH_ALL;
}
