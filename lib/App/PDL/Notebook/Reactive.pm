package App::PDL::Notebook::Reactive;
use strict;
use warnings;
use Scalar::Util ();

# ===========================================================================
# The generic side of the "drop Prima/Tk, use a typed parameter channel"
# design (docs/reactive-controls.md).
#
# This module owns the TRANSPORT and REGISTRY only:
#   * declared parameters (type, value, bounds)  -> widget descriptors
#   * inbound {control,value} events             -> value updates + re-runs
#
# It is deliberately PDL-agnostic. The ergonomic, piddle-aware sugar
#   ( $fig->param('cutoff', 0.5, min=>0, max=>1); $fig->on_change(sub{...}); )
# belongs in PDL::Graphics::Cairo and is expected to drive this registry.
#
# STATUS: skeleton. Wired neither into the kernel loop nor the frontend yet --
# that is the next implementation step (see the HOOKS section below).
# ===========================================================================

# name => { type, value, label, group, min, max, step, options }
our %PARAM;
# group => [ coderef, ... ]   re-run at CLOSURE granularity, never whole cells
our %HANDLER;
# emission order, so descriptors render in declaration order
our @ORDER;

sub reset {
    %PARAM = ();
    %HANDLER = ();
    @ORDER = ();
    return;
}

# declare/replace a parameter; returns its current value
#   param('cutoff', 0.5, type=>'number', min=>0, max=>1, step=>0.01, group=>'g1')
#   param('logscale', 0, type=>'bool')
#   param('mode', 'a', type=>'enum', options=>['a','b','c'])
sub param {
    my ($name, $default, %opt) = @_;
    if (!exists $PARAM{$name}) {
        push @ORDER, $name;
        $PARAM{$name} = { value => $default, %opt, type => ($opt{type} // 'number') };
    }
    return $PARAM{$name}{value};
}

sub value { exists $PARAM{$_[0]} ? $PARAM{$_[0]}{value} : undef }

# set_value: overwrite a param value without firing callbacks
# Used internally (e.g. _key handler updates _pos before calling $render)
sub set_value {
    my ($name, $val) = @_;
    return unless exists $PARAM{$name};
    $PARAM{$name}{value} = $val unless $PARAM{$name}{type} eq 'button';
    return;
}

# a button is just an event-typed param with no persistent value
sub button {
    my ($name, %opt) = @_;
    push @ORDER, $name unless exists $PARAM{$name};
    $PARAM{$name} = { %opt, type => 'button' };
    return;
}

# register a closure to re-run when any param in $group changes
sub on_change {
    my ($cb, $group) = @_;
    $group //= '_default';
    push @{ $HANDLER{$group} }, $cb;
    return;
}

# widget descriptors to ship to the frontend alongside the figure output
sub descriptors {
    return [ map { { name => $_, %{ $PARAM{$_} } } } @ORDER ];
}

# handle one inbound control event: update the value, re-run affected closures
sub handle_event {
    my ($name, $val) = @_;
    # _key is a synthetic event (ArrowLeft/Right) — not declared as a param,
    # but we route it to the '_key' handler group so cells can listen with:
    #   on_change(sub{ ... }, '_key');
    if ($name eq '_key') {
        $_->($name, $val) for @{ $HANDLER{_key} // [] };
        return;
    }
    return unless exists $PARAM{$name};
    $PARAM{$name}{value} = $val unless $PARAM{$name}{type} eq 'button';
    my $group = $PARAM{$name}{group} // '_default';
    $_->($name, $val) for @{ $HANDLER{$group} // [] };
    return;
}

1;

__END__

=head1 HOOKS (next implementation step)

=over 4

=item Kernel

After running a cell, emit C<descriptors()> as a C<{type=>'widgets', specs=>...}>
message (next to the C<display> messages). Add a new inbound message type
C<{type=>'event', control=>..., value=>...}> that calls C<handle_event> and then
re-drains the display queue -- re-running only the registered closure, not the
whole cell. Continuous controls (sliders) should be debounced on the frontend.

=item Frontend

Render each descriptor as the matching HTML control (number=>range, bool=>toggle,
enum=>select, button=>button) under the figure, and send C<event> messages on
change. Browser controls are free here; a native viewer can render cheap native
controls from the same descriptors -- one protocol, two frontends (the ipywidgets
comm model).

=item Cairo

C<PDL::Graphics::Cairo> provides C<< $fig->param >>/C<< ->button >>/C<< ->on_change >>
that call into this registry, so plotting code reads naturally and stays
piddle-centric.

=back

=cut
