# App-PDL-Notebook

A lightweight, Jupyter-style notebook for PDL — **no ZeroMQ, no Python/Jupyter
stack, no Node-built frontend.** Just a persistent Perl interpreter, a thin
Mojolicious WebSocket relay, and one static HTML page.

```
browser (CodeMirror cells)
   │  WebSocket (JSON)
script/pdl-notebook          ← Mojolicious::Lite, relay only
   │  pipes (newline-delimited JSON)
script/pdl-notebook-kernel   ← persistent PDL interpreter, one cell at a time
```

## Layout

```
App_PDL_Notebook/                         (~/src/App_PDL_Notebook ; dist: App-PDL-Notebook)
├── Makefile.PL
├── cpanfile
├── README.md
├── lib/App/PDL/
│   ├── Notebook.pm                        main module + overview/contracts
│   └── Notebook/
│       ├── Display.pm                     per-cell output queue + repr()
│       └── Reactive.pm                    reactive param/event registry (skeleton)
├── script/
│   ├── pdl-notebook                       server entry  (perl script/pdl-notebook daemon …)
│   └── pdl-notebook-kernel                kernel entry  (spawned by the server)
├── public/
│   └── index.html                         the notebook UI
├── docs/
│   ├── inline-backend.md                  contract for PDL::Graphics::Cairo::Backend::Inline
│   └── reactive-controls.md               the "drop Prima" control-channel design
└── t/
    └── 00-load.t
```

The Cairo inline backend is **not** in this dist by design — it speaks piddles,
so it belongs in `PDL::Graphics::Cairo` as `Backend::Inline`. This dist stays
graphics-agnostic and meets it through a callback (see `docs/inline-backend.md`).

## Install / run

```sh
# prerequisites
cpanm Mojolicious Lexical::Persistence       # + PDL on your system already
# (Lexical::Persistence is optional; without it `my` vars don't persist across cells)

# run from the checkout
export PERL5LIB=~/src/PDL_Graphics_Cairo/lib:$PERL5LIB   # + your own module paths
perl script/pdl-notebook daemon -l http://*:3000
#   or, with auto-reload during development:
morbo script/pdl-notebook

# then open http://localhost:3000
```

The kernel inherits the server's environment, so PDL and your own modules just
need to be on `PERL5LIB` when you launch.

## Will it run after download?

**Yes — for the notebook itself**, once the prerequisites are present:

| works out of the box (Perl + Mojolicious + PDL) | needs one more step |
|---|---|
| editing cells, Shift-Enter to run | **inline figures** — install/​wire `PDL::Graphics::Cairo::Backend::Inline` (it's not in this dist; see `docs/inline-backend.md`). Until then plotting either opens a window or no-ops. |
| `stdout` / `stderr` / errors per cell | **`my` persistence across cells** — needs `Lexical::Persistence`; without it use `our`/package vars (the UI shows a one-line warning). |
| last-expression result, PDL repr | **reactive controls** (sliders/toggles/buttons) — registry exists, but not yet wired into the kernel loop or frontend (`docs/reactive-controls.md`). |
| interrupt button (SIGINT) | the browser fetches CodeMirror + fonts from CDNs, so the **frontend needs internet** (or vendor those assets locally). |

Quick sanity check without a browser:

```sh
prove -Ilib t/                               # load + registry + repr tests
printf '%s\n' '{"id":1,"code":"my $x = sequence(5); $x**2"}' \
  | perl -Ilib script/pdl-notebook-kernel    # should emit a result frame
```

## Known limitations (deliberately left to tighten)

- **Single kernel, single user.** Multi-user → one kernel per WebSocket
  connection, keyed by connection id; the relay is otherwise unchanged.
- **Output capture is Perl-level only.** `local *STDOUT` catches Perl prints, but
  C-level writes to fd 1 (some PDL/Cairo paths) bypass it *and* would corrupt the
  protocol, since the channel is a dup of fd 1. The clean fix is to move the
  protocol onto a dedicated fd (e.g. fd 3) and redirect fd 1/2 at the OS level
  around each cell.
- **Interrupt = SIGINT** turns a running cell into a catchable `die`; for a wedged
  cell, have the server `SIGKILL` and respawn.
- **`public/` is resolved relative to `script/`.** Run from the checkout; an
  installed copy would want `File::ShareDir`.
- **`.ipynb` interop** not implemented (the on-disk format is just JSON — a small,
  optional addition for Jupyter portability).
```
