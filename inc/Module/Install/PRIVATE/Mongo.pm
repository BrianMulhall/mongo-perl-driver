#line 1
use strict;
use warnings;

package Module::Install::PRIVATE::Mongo;

use Module::Install::Base;
use Config;
use Config::AutoConf;
use Path::Tiny;
use File::Spec::Functions qw/catdir/;
use Cwd; 

use vars qw{$VERSION @ISA};
BEGIN {
    $VERSION = '0.45';
    @ISA     = qw{Module::Install::Base};
}

sub mongo {
    my ($self, @mongo_vars) = @_;
    my $ccflags = $self->makemaker_args->{CCFLAGS} || $Config{ccflags};
    $ccflags = "" unless defined $ccflags;

    if ($Config{osname} eq 'darwin') {
        my @arch = $Config::Config{ccflags} =~ m/-arch\s+(\S+)/g;
        my $archStr = join '', map { " -arch $_ " } @arch;

        $ccflags = $ccflags . $archStr;

        $self->makemaker_args(
            dynamic_lib => {
                OTHERLDFLAGS => $archStr
            }
        );

        $ccflags = $ccflags . ' -g -pipe -fno-common -DPERL_DARWIN -no-cpp-precomp -fno-strict-aliasing -Wdeclaration-after-statement -I/usr/local/include';
        $self->makemaker_args( LDDLFLAGS => ' -bundle -undefined dynamic_lookup -L/usr/local/lib');
    }

    # check for big-endian
    my $endianess = $Config{byteorder};
    if ($endianess == 4321 || $endianess == 87654321) {
        $ccflags .= " -DMONGO_BIG_ENDIAN=1 ";
    }

    # needed to compile bson library
    $ccflags .= " -DBSON_COMPILATION ";

    my $conf = $self->configure_bson;

    if ($conf->{BSON_WITH_OID32_PT} || $conf->{BSON_WITH_OID32_PT}) {
        my $pthread = $^O eq 'solaris' ? " -pthreads " : " -pthread ";
        $ccflags .= $pthread;
        my $ldflags = $self->makemaker_args->{LDFLAGS};
        $ldflags = "" unless defined $ldflags;
        $self->makemaker_args( LDFLAGS => "$ldflags $pthread" );
    }

    if ( $conf->{BSON_HAVE_CLOCK_GETTIME} ) {
        my $libs = $self->makemaker_args->{LIBS};
        $libs = "" unless defined $libs;
        $self->makemaker_args( LIBS => "$libs -lrt" );
    }

    $self->makemaker_args( CCFLAGS => $ccflags );

    $self->xs_files;

    $self->makemaker_args( INC   => '-I. -Ibson -Iyajl' );

    return;
}

sub xs_files {
    my ($self) = @_;
    my (@clean, @OBJECT, %XS);

    for my $xs (<xs/*.xs>) {
        (my $c = $xs) =~ s/\.xs$/.c/i;
        (my $o = $xs) =~ s/\.xs$/\$(OBJ_EXT)/i;

        $XS{$xs} = $c;
        push @OBJECT, $o;
        push @clean, $o;
    }

    for my $c (<*.c>, <bson/*.c>, <yajl/*.c>) {
        (my $o = $c) =~ s/\.c$/\$(OBJ_EXT)/i;

        push @OBJECT, $o;
        push @clean, $o;
    }

    $self->makemaker_args(
        clean  => { FILES => join(q{ }, @clean) },
        OBJECT => join(q{ }, @OBJECT),
        XS     => \%XS,
    );

    $self->postamble('$(OBJECT) : perl_mongo.h');

    return;
}

# Quick and dirty autoconf substitute
sub configure_bson {
    my ($self) = @_;

    my $conf = $self->probe_bson_config;

    path("bson/bson-stdint.h")->spew("#include <$conf->{STDINT_SOURCE}>");

    my $config_guts = path("bson/bson-config.h.in")->slurp;
    for my $key ( %$conf ) {
        $config_guts =~ s/\@$key\@/$conf->{$key}/;
    }
    path("bson/bson-config.h")->spew($config_guts);

    return $conf;
}

sub probe_bson_config {
    my ($self) = @_;
    my $ca = Config::AutoConf->new;
    $ca->push_lang("C");
    my %conf;

    # what should bson-stdint.h load?  If the system doesn't have stdint.h,
    # we try a "portable" equilvalent.  libbson's autoconfig rules are smarter
    # but this may do for now.  Generally, stdint.h should be available on most
    # platforms: see http://hacks.owlfolio.org/header-survey/
    $conf{STDINT_SOURCE} = $ca->check_header("stdint.h") ? "stdint.h" : "pstdint.h";

    ##/*
    ## * Define to 1234 for Little Endian, 4321 for Big Endian.
    ## */
    $conf{BSON_BYTE_ORDER} = $Config{byteorder} =~ /^1234/ ? '1234' : '4321';

    ##/*
    ## * Define to 1 if you have stdbool.h
    ## */
    $conf{BSON_HAVE_STDBOOL_H} = $Config{i_stdbool} ? 1 : 0;

    ##/*
    ## * Define to 1 for POSIX-like systems, 2 for Windows.
    ## */
    $conf{BSON_OS} = $^O eq 'MSWin32' ? 2 : 1;

    ##/*
    ## * Define to 1 if your system requires {} around PTHREAD_ONCE_INIT.
    ## * This is typically just Solaris 8-10.
    ## */

    ##/*
    ## * Define to 1 if you have clock_gettime() available.
    ## */
    ## XXX also needs to link -lrt for this to work
    {
        my $ca = Config::AutoConf->new;
        $ca->push_libraries('rt');
        $conf{BSON_HAVE_CLOCK_GETTIME} = $ca->link_if_else(
            $ca->lang_call("", "clock_gettime")
        ) ? 1 : 0;
    }

    ##/*
    ## * Define to 1 if you have strnlen available on your platform.
    ## */
    $conf{BSON_HAVE_STRNLEN} = $ca->link_if_else(
        $ca->lang_call("", "strnlen")
    ) ? 1 : 0;

    ##/*
    ## * Define to 1 if you have snprintf available on your platform.
    ## */
    $conf{BSON_HAVE_SNPRINTF} = $Config{d_snprintf} ? 1 : 0;

    ## pthread-related configuration
    if ( $^O eq 'MSWin32' ) {
        $conf{$_} = 0 for qw/BSON_PTHREAD_ONCE_INIT_NEEDS_BRACES BSON_WITH_OID64_PT BSON_WITH_OID32_PT/;
    }
    else {

        $conf{BSON_PTHREAD_ONCE_INIT_NEEDS_BRACES} = $ca->link_if_else(<<'HERE') ? 0 : 1;
#include <pthread.h>
pthread_once_t foo = PTHREAD_ONCE_INIT;
int
main ()
{
;
return 0;
}
HERE

    ##/*
    ## * Define to 1 if 32-bit atomics are not available and pthreads should be
    ## * used to emulate them.
    ## */
    $conf{BSON_WITH_OID32_PT} = $ca->link_if_else(<<'HERE') ? 0 : 1;
#include <stdint.h>
int
main ()
{
    uint32_t seq = __sync_fetch_and_add_4(&seq, 1);
    return 0;
}
HERE

    ##/*
    ## * Define to 1 if 64-bit atomics are not available and pthreads should be
    ## * used to emulate them.
    ## */
    $conf{BSON_WITH_OID64_PT} = $ca->link_if_else(<<'HERE') ? 0 : 1;
#include <stdint.h>
int
main ()
{
    uint64_t seq = __sync_fetch_and_add_8(&seq, 1);
    return 0;
}
HERE
    }

    return \%conf;
}
1;

