# Reactive controls — replacing Prima/Tk panels

Goal: toggles, buttons, and three-or-more sliders driving live re-renders —
without rebuilding a native GUI toolkit. The move is to **drop the toolkit** and
ship a typed parameter/event channel instead, so the *widgets* are drawn by
whichever frontend is attached (HTML controls in the browser; cheap native
controls in a native viewer). One protocol, two frontends — the ipywidgets comm
model, which fits the persistent kernel exactly.

The hard part is already solved: the giza-server bidirectional slider protocol
(`GSP_MSG_SLIDER=0x13`, ACK-interleaved). Generalise "slider" to "typed
parameter + event" and the rest follows.

## API (what plotting code writes)

The ergonomic sugar is piddle-aware, so it lives in **`PDL::Graphics::Cairo`**:

```perl
my $cut = $fig->param('cutoff', 0.5, min => 0, max => 1);  # slider
my $log = $fig->param('logscale', 0, type => 'bool');       # toggle
$fig->button('recompute', sub { ... });                     # event
$fig->on_change(sub {
    $fig->imshow( filtered($data, $cut->value, $log->value) );
});
```

## Registry (the generic core — `App::PDL::Notebook::Reactive`)

PDL-agnostic. Holds declared params (type, value, bounds), maps inbound
`{control,value}` events to value updates, and re-runs the registered closures.
Already implemented as a skeleton in `lib/App/PDL/Notebook/Reactive.pm`.

## Wire protocol (the next implementation step)

```
kernel -> frontend   {"type":"widgets","id":N,"specs":[ {name,type,value,min,max,...}, ... ]}
frontend -> kernel   {"type":"event","control":"cutoff","value":0.7}
```

On an `event`, the kernel calls `Reactive::handle_event`, which updates the value
and runs only the closures registered for that parameter's group, then re-drains
the display queue.

## The one rule that matters

**Re-run at closure granularity, not whole cells.** Both Prima and ipywidgets
register callbacks for exactly this reason: re-running the whole cell on every
slider tick would re-execute heavy upstream computation each frame. Continuous
controls (sliders) debounce on the frontend; discrete ones (toggles, buttons)
fire immediately.

## Namespace split (per the "does the API speak piddles?" rule)

| piece | speaks piddles? | home |
|-------|-----------------|------|
| `$fig->param/->button/->on_change` ergonomics | yes | `PDL::Graphics::Cairo` |
| typed-parameter registry + event routing       | no  | `App::PDL::Notebook::Reactive` |
| widget descriptor transport                     | no  | `App::PDL::Notebook` protocol |
| control rendering                               | no  | frontend (HTML / native) |

Cairo never learns *how* a control is drawn; it is only told a parameter changed.
That boundary is the layer giza-server already implements.
