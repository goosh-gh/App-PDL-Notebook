package App::PDL::Notebook::Display;
use strict;
use warnings;
use MIME::Base64 ();
use Scalar::Util ();

# ---------------------------------------------------------------------------
# Per-cell rich-output queue + repr() dispatch.
#
# This is the lightweight equivalent of matplotlib's "pyplot collects the
# figures created during the cell, then the inline backend flushes them".
# Anything that wants a picture / table / html in a cell's output pushes a
# {mime,data} record here; the kernel drains @QUEUE after each cell.
#
# NOTE: rendering a piddle to bytes is NOT done here -- that is Cairo's job.
# PDL::Graphics::Cairo::Backend::Inline produces the bytes and calls the
# publish_* helpers below via the publisher callback (see App::PDL::Notebook).
# ---------------------------------------------------------------------------

our @QUEUE;

sub reset_queue { @QUEUE = (); return }

sub publish {
    my ($mime, $data) = @_;
    push @QUEUE, { mime => $mime, data => $data };
    return;
}

sub publish_png  { publish('image/png',     MIME::Base64::encode_base64($_[0], '')) }
sub publish_svg  { publish('image/svg+xml', $_[0]) }   # raw svg text passes through
sub publish_html { publish('text/html',     $_[0]) }
sub publish_text { publish('text/plain',    $_[0]) }

# ---------------------------------------------------------------------------
# repr(): turn a cell's last-expression value into a (mime, data) pair.
# Dispatch mirrors Jupyter's _repr_*_ protocol as a duck-typed method check.
# ---------------------------------------------------------------------------

sub repr {
    my ($v) = @_;
    return unless defined $v;

    if (Scalar::Util::blessed($v)) {
        if ($v->can('to_inline')) {
            my ($mime, $data) = $v->to_inline;
            $data = MIME::Base64::encode_base64($data, '') if $mime eq 'image/png';
            return ($mime, $data);
        }
        return ('image/svg+xml', $v->to_svg)  if $v->can('to_svg');
        return ('image/png', MIME::Base64::encode_base64($v->to_png, ''))
                                               if $v->can('to_png');
        return ('text/html', $v->to_html)      if $v->can('to_html');
        return ('text/plain', _pdl_repr($v))   if $v->isa('PDL');
    }
    return ('text/plain', "$v");
}

# A piddle can be huge, so never dump a large one as text: show shape/type (and
# a small data block only when it is small enough to be useful). The visual
# "big array as a heatmap" path is handled by the Cairo to_png/to_svg branch
# above -- this is just the fallback.
sub _pdl_repr {
    my ($p) = @_;
    my $head = eval { $p->info('%C: %T %D') } // "$p";
    my $n    = eval { $p->nelem } // 0;
    return $head if $n == 0 || $n > 200;
    return "$head\n$p";
}

1;
