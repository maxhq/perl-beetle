#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw/$RealBin/;
use Cwd qw/abs_path/;
use Perl::Tidy;
use File::Next;
use File::Copy;
use File::Spec;

my $path = abs_path( File::Spec->catdir( $RealBin, '..' ) );

my $files = File::Next::files($path);

while ( defined( my $file = $files->() ) ) {
    next if ( $file !~ /\.(p[ml]|t)$/ );
    next if ( $file =~ /perltidy/ );

    print "$file\n";

    my $tidyfile = $file . '.tdy';
    Perl::Tidy::perltidy(
        source      => $file,
        destination => $tidyfile,
        perltidyrc  => File::Spec->catfile( $RealBin, '../.perltidyrc' ),
    );

    move( $tidyfile, $file );
}

1;
