requires 'perl', '5.020';

requires 'Mojolicious', '9.0';
requires 'JSON::PP';
requires 'MIME::Base64';
requires 'Scalar::Util';
requires 'IPC::Open2';

# Recommended -- the notebook core is PDL-agnostic and degrades gracefully
# without these, but you almost certainly want them:
recommends 'Lexical::Persistence';   # `my` variables persist across cells
recommends 'PDL';                    # the point of the notebook
recommends 'PDL::Graphics::Cairo';   # inline figures, via Backend::Inline
                                     #   (Backend::Inline ships in the Cairo dist,
                                     #    not here -- see docs/inline-backend.md)

on 'test' => sub {
    requires 'Test::More';
};
