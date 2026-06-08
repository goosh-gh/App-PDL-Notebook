package App::PDL::Notebook;
use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

App::PDL::Notebook - a lightweight, Jupyter-style notebook for PDL without
ZeroMQ or the Jupyter stack

=head1 SYNOPSIS

    # from a source checkout (~/src/App_PDL_Notebook):
    perl script/pdl-notebook daemon -l http://*:3000
    # open http://localhost:3000

=head1 DESCRIPTION

A cell-based notebook for PDL whose moving parts are just a persistent Perl
interpreter, a thin Mojolicious WebSocket relay, and one static HTML page. No
ZeroMQ, no Python, no Node-built frontend.

    browser (CodeMirror cells)
       |  WebSocket (JSON)
    script/pdl-notebook            Mojolicious::Lite, relay only
       |  pipes (newline-delimited JSON)
    script/pdl-notebook-kernel     persistent interpreter, one cell at a time

The notebook machinery is deliberately PDL-agnostic. PDL enters only through

=over 4

=item *

the kernel's default prelude (a single configurable C<use PDL ...> string), and

=item *

the rich-display path, where L<App::PDL::Notebook::Display> dispatches on a
value's C<to_svg>/C<to_png>/C<to_html> methods and falls back to a compact PDL
repr.

=back

=head1 INLINE FIGURES (the publisher contract)

Rendering a piddle to a picture is PDL's job, not the notebook's, so it lives in
the C<PDL::Graphics::Cairo> distribution as C<PDL::Graphics::Cairo::Backend::Inline>
(see F<docs/inline-backend.md>). The two sides meet through a callback: at
startup the kernel registers a publisher,

    PDL::Graphics::Cairo::Backend::Inline::set_publisher(sub {
        my ($mime, $bytes) = @_;
        App::PDL::Notebook::Display::publish_png($bytes) if $mime eq 'image/png';
        App::PDL::Notebook::Display::publish_svg($bytes) if $mime eq 'image/svg+xml';
    });

so the Cairo backend knows nothing about the notebook, and the notebook knows
nothing about Cairo internals. If the inline backend is not installed, the
kernel skips registration and the rest of the notebook works unchanged.

=head1 REACTIVE CONTROLS

The replacement for L<PDL::Graphics::Prima>-style control panels (toggles,
buttons, multiple sliders) is a typed parameter/event channel rather than a
native toolkit. The generic registry lives in L<App::PDL::Notebook::Reactive>;
the C<< $fig->param(...) >> ergonomics that emit it belong in
C<PDL::Graphics::Cairo>. See F<docs/reactive-controls.md>.

=head1 SEE ALSO

L<perldl>, L<Devel::IPerl>, L<App::Prima::REPL>

=cut
