#!/usr/bin/env perl
use strict;
use warnings;
use PDL;
use PDL::Graphics::Cairo;

# ---------------------------------------------------------------------------
# probe_pgc.pl  --  answer two questions before wiring inline display:
#   1) what is the Figure object's "save to file" method actually called?
#   2) does plotting with the default backend open a window?
#
# Run:  /opt/local/bin/perl5.40.4 probe_pgc.pl
# ---------------------------------------------------------------------------

print "PDL::Graphics::Cairo from: ", ($INC{'PDL/Graphics/Cairo.pm'} // '?'), "\n";
print "version: ", ($PDL::Graphics::Cairo::VERSION // '?'), "\n\n";

# --- 1. Figure class: which methods look like save / render? ----------------
print "== PDL::Graphics::Cairo::Figure:: methods (save/print/write/flush/draw/render/to_) ==\n";
for my $name (sort keys %PDL::Graphics::Cairo::Figure::) {
    next unless $name =~ /save|print|write|flush|draw|render|to_|show/i;
    next unless defined &{"PDL::Graphics::Cairo::Figure::$name"};
    print "  \$fig->$name\n";
}
print "== top-level functions (plot/line/imshow/figure/subplot/show) ==\n";
for my $name (sort keys %PDL::Graphics::Cairo::) {
    next unless $name =~ /plot|line|imshow|figure|subplot|show/i;
    next unless defined &{"PDL::Graphics::Cairo::$name"};
    print "  $name\n";
}
print "\n";

# --- 2. make a minimal plot (best-effort across the documented APIs) --------
my $x = sequence(40) / 6;
my $y = sin($x);

my @attempts = (
    [ 'subplots + $ax->plot' => sub {
        my ($f, $ax) = PDL::Graphics::Cairo::subplots();
        $ax->plot($x, $y);
        $f->tight_layout if $f->can('tight_layout');
        $f;
    } ],
    [ 'new + $fig->plot' => sub {
        my $f = PDL::Graphics::Cairo->new;
        $f->plot($x, $y);
        $f->tight_layout if $f->can('tight_layout');
        $f;
    } ],
    [ 'new + $fig->line' => sub {
        my $f = PDL::Graphics::Cairo->new;
        $f->line($x, $y);
        $f->tight_layout if $f->can('tight_layout');
        $f;
    } ],
);

my $fig;
for my $a (@attempts) {
    my ($label, $code) = @$a;
    my $r = eval { $code->() };
    if ($r) { $fig = $r; print "plot OK via: $label   (fig = $fig)\n"; last }
    (my $err = $@ // '') =~ s/\n.*//s;
    print "  tried [$label] -> $err\n";
}
die "\nCould not plot with any known API -- paste the method list above.\n" unless $fig;

# --- 3. which driver/backend actually got loaded? ---------------------------
print "\n== loaded Driver modules (this is your default backend) ==\n";
my @drv = grep { m{PDL/Graphics/Cairo/Driver} } sort keys %INC;
print "  $_\n" for @drv;
print "  (none loaded)\n" unless @drv;

# --- 4. window signal: is giza_server running? ------------------------------
print "\n== giza_server process check ==\n";
system('pgrep -fl giza_server || echo "  (no giza_server process running)"');

# --- 5. naked-eye window watch ----------------------------------------------
print "\n>>> WATCH YOUR SCREEN for the next 6 seconds: does a plot window open?\n";
sleep 6;

# --- 6. discover & exercise the save method ---------------------------------
print "\n== trying to save to file ==\n";
my @savers = grep { /save/i && defined &{"PDL::Graphics::Cairo::Figure::$_"} }
             sort keys %PDL::Graphics::Cairo::Figure::;
print "  save-like methods found: @{[ @savers ? @savers : '(none -- check list above)' ]}\n";

for my $ext (qw(png svg)) {
    my $fn = "/tmp/pgc_probe.$ext";
    my $done;
    for my $m (@savers ? @savers : ('savefig')) {
        if (eval { $fig->$m($fn); 1 }) {
            printf "  \$fig->%s(\"%s\") -> %d bytes\n", $m, $fn, (-s $fn // 0);
            $done = 1; last;
        }
    }
    print "  could not save .$ext\n" unless $done;
}

print "\nDONE.\n";
print "If the script reached DONE without hanging, no *blocking* GUI mainloop opened.\n";
print "A window may still be open via giza_server (see the process check above).\n";
