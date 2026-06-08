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

# NOT on CPAN -- installed from GitHub (github.com/goosh-gh), so they cannot be
# included in the CPAN prerequisites; see README "Dependencies not on CPAN":
#   PDL::Graphics::Cairo   inline figures (provides ->to_inline/to_svg/to_png)
#   PDL::IO::PNG           fast image read, optional

on 'test' => sub {
    requires 'Test::More';
};
