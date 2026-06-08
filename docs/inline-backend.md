# Inline figures — the `PDL::Graphics::Cairo::Backend::Inline` contract

Rendering a piddle to a picture is PDL's job, so the renderer lives in the
**`PDL::Graphics::Cairo`** distribution, next to `/osx` and gnuplot, as a backend
named `inline`. This notebook never rasterises anything; it only receives bytes.

## How the two sides meet

A single callback. The notebook kernel, at startup, registers a publisher:

```perl
PDL::Graphics::Cairo::Backend::Inline::set_publisher(sub {
    my ($mime, $bytes) = @_;
    App::PDL::Notebook::Display::publish_png($bytes)  if $mime eq 'image/png';
    App::PDL::Notebook::Display::publish_svg($bytes)  if $mime eq 'image/svg+xml';
});
```

So the Cairo backend depends on nothing from the notebook, and the notebook
depends on nothing from Cairo internals. If the backend is absent, the kernel's
registration `eval` simply fails and the text notebook works unchanged.

## What `Backend::Inline` must provide

```perl
package PDL::Graphics::Cairo::Backend::Inline;
our $PUBLISH;                       # coderef: ($mime, $bytes) -> void
sub set_publisher { $PUBLISH = $_[0] }
sub active        { defined $PUBLISH }
```

…plus the render path. Two ways to feed it, easiest first:

**(A) Reuse the bytes you already have.** You build a PNG for the Cocoa viewer
(the `last_png` buffer from server7). In notebook mode, hand those bytes to the
publisher instead of piping them to `pdlcairo_viewer`:

```perl
$PUBLISH->('image/png', $last_png) if $PUBLISH;
```

That alone gives working inline raster plots with almost no new code.

**(B) Vector output.** Render the figure to an in-memory SVG via a Cairo SVG
surface and publish that — this is where the server8 reverse-channel vector work
pays off as crisp inline SVG:

```perl
sub _render_svg {
    my ($self, $w, $h) = @_;
    require Cairo; require File::Temp;
    my ($fh, $fn) = File::Temp::tempfile(SUFFIX => '.svg', UNLINK => 1);
    close $fh;
    my $surf = Cairo::SvgSurface->create($fn, $w, $h);
    my $cr   = Cairo::Context->create($surf);
    $self->_paint($cr);             # the same draw path that produces last_png
    $cr->show_page; $surf->finish;
    open my $r, '<:raw', $fn; local $/; my $svg = <$r>; close $r;
    return $svg;
}
```

(Temp file rather than `write_to_png_stream` / a stream callback: the callback
signature varies across Cairo binding versions, and the cost is irrelevant at
notebook plotting rates.)

## Routing

Add `'inline'` as a candidate in `_default_backend()`, guarded so it only wins
inside the notebook — e.g. when `set_publisher` has been called
(`Backend::Inline::active()`), or behind an env var the kernel sets for its
children. Everywhere else, keep opening windows.
```perl
my $backend = $opt{backend}
           // $ENV{PDLCAIRO_BACKEND}
           // (PDL::Graphics::Cairo::Backend::Inline::active() ? 'inline' : _detect());
```

## Rich display for piddles directly

`App::PDL::Notebook::Display::repr()` checks a value's `to_svg`/`to_png`/`to_html`
before falling back to a text repr. Giving `PDL` (or a thin wrapper) a `to_png`
that renders a large 2-D piddle as a heatmap turns "the last expression was a
4096×4096 array" into an image instead of a wall of numbers — the place where
PDL's big-array strength actually shows up in a notebook.
