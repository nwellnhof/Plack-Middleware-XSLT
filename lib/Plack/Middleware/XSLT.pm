package Plack::Middleware::XSLT;
use strict;

# ABSTRACT: XSLT transformations with Plack

use parent 'Plack::Middleware';

use Cwd ();
use File::Spec;
use HTTP::Exception;
use Plack::Response;
use Plack::Util::Accessor qw(cache path);
use Try::Tiny;
use URI;
use XML::LibXML;
use XML::LibXSLT;

my $parser = XML::LibXML->new();
$parser->no_network(1) if $XML::LibXML::VERSION >= 1.63;
# work-around to fix indenting
$parser->keep_blanks(0) if $XML::LibXML::VERSION < 1.70;

my $xslt = XML::LibXSLT->new();
my $icb = XML::LibXML::InputCallback->new();
$icb->register_callbacks([ \&match_cb, \&open_cb, \&read_cb, \&close_cb ]);
$xslt->input_callbacks($icb);

my (%cache, $dependencies, $deps_ok);
my $cache_hits = 0;

# Returns the absolute path of a stylesheet file

sub abs_style {
    my ($self, $style) = @_;

    if (!File::Spec->file_name_is_absolute($style)) {
        my $path = $self->path;
        $style = File::Spec->rel2abs($style, $path) if defined($path);
    }

    return Cwd::abs_path($style);
}

sub call {
    my ($self, $env) = @_;

    my $r = $self->app->($env);

    my $style = $env->{'xslt.style'};

    return $r if !defined($style) || $style eq '';

    my ($status, $headers, $body) = @$r;
    my $doc = $self->_parse_body($body);

    my ($output, $media_type, $encoding) = $self->xform($style, $doc);

    if($XML::LibXSLT::VERSION < 1.61 && $media_type eq 'text/html') {
        # <xsl:terminate terminate="yes"> doesn't die in XML::LibXSLT
        # versions before 1.61

        HTTP::Exception::NOT_FOUND->throw() if $output !~ /<body/;
    }

    my $res = Plack::Response->new($status, $headers, $output);
    $res->content_type("$media_type; charset=$encoding");
    $res->content_length(length($output));

    return $res->finalize();
}

sub xform {
    my ($self, $style, $doc) = @_;

    my $stylesheet = $self->parse_stylesheet_file($style);

    my $result = try {
        $stylesheet->transform($doc) or die("XSLT transform failed: $!");
    }
    catch {
        for my $line (split(/\n/, $_)) {
            HTTP::Exception->throw($1) if $line =~ /^(\d\d\d)(?:\s|\z)/;
        }
        die($_);
    };

    my $output = $stylesheet->output_string($result);
    my $media_type = $stylesheet->media_type();
    my $encoding = $stylesheet->output_encoding();

    #utf8::encode($output) if utf8::is_utf8($output);

    # Hack for old libxslt versions and imported stylesheets
    $media_type = 'text/html' if $media_type eq 'text/xml' && (
        $XML::LibXSLT::VERSION < 1.62 ||
        XML::LibXSLT::LIBXSLT_VERSION() < 10125);

    return ($output, $media_type, $encoding);
}

sub _parse_body {
    my ($self, $body) = @_;

    my $doc;

    if (Plack::Util::is_real_fh($body)) {
        die('fh not supported');
    }
    elsif (ref($body) eq 'ARRAY') {
        my $xml = join('', @$body);

        $doc = $parser->parse_string($xml);
    }
    else {
        die("unknown body type: $body");
    }

    return $doc;
}

sub parse_stylesheet_file {
    my ($self, $style) = @_;

    my $filename = $self->abs_style($style);

    return $xslt->parse_stylesheet_file($filename) if !$self->cache;

    my @stat = stat($filename) or die("stat: $!");
    my $mtime = $stat[9];
    my $cache_rec = $cache{$filename};

    if ($cache_rec) {
        my ($cached_ss, $cached_time, $deps) = @$cache_rec;

        if ($mtime == $cached_time) {
            # check mtimes of dependencies

            my $stale;

            while (my ($path, $cached_time) = each(%$deps)) {
                my @stat = stat($path);
                my $mtime = @stat ? $stat[9] : -1;
                $stale = $mtime != $cached_time;
            }

            if (!$stale) {
                ++$cache_hits;
                return $cached_ss;
            }
        }
    }

    $dependencies = {};
    $deps_ok = 1;

    my $stylesheet = $xslt->parse_stylesheet_file($filename);

    goto no_store if !$deps_ok;

    delete($dependencies->{$filename});

    $cache_rec = [ $stylesheet, $mtime, $dependencies ];
    $cache{$filename} = $cache_rec;
    $dependencies = undef;

    return $stylesheet;

no_store:
    delete($cache{$filename});
    $dependencies = undef;

    return $stylesheet;
}

sub cache_record {
    my ($self, $style) = @_;

    my $filename = $self->abs_style($style);
    my $cache_rec = $cache{$filename} or return ();

    return @$cache_rec;
}

sub cache_hits {
    return $cache_hits;
}

# Handling of dependencies

# We register an input callback that never matches but records all URIs
# that are accessed during parsing of the stylesheet.

sub match_cb {
    my $uri_str = shift;

    return undef if !$dependencies;

    my $uri = URI->new($uri_str, 'file');
    my $scheme = $uri->scheme;

    if (!defined($scheme) || $scheme eq 'file') {
        my $path = Cwd::abs_path($uri->path);
        my @stat = stat($path);
        $dependencies->{$path} = @stat ? $stat[9] : -1;
    }
    else {
        $deps_ok = undef;
    }

    return undef;
}

# should never be called
sub open_cb { die('open callback called'); }
sub read_cb { die('read callback called'); }
sub close_cb { die('close callback called'); }

1;

__END__

=head1 SYNOPSIS

    # in your .psgi

    enable 'XSLT';

    # in your app

    $env->{'xslt.style'} = 'stylesheet.xsl';

    return [ 200, $headers, [ $xml ] ];

=head1 DESCRIPTION

Plack::Middleware::XSLT converts XML response bodies to HTML, XML, or text
using XML::LibXSLT. The XSLT stylesheet is specified by the environment
variable 'xslt.style'. This rather crude mechanism might be enhanced in
the future.

The Content-Type header is set according to xsl:output. Content-Length is
adjusted.

=head1 CONFIGURATION

=over 4

=item path

    enable 'XSLT', path => 'path/to/xsl/files';

Sets a path that will be prepended if xslt.style contains a relative path.
Defaults to the current directory.

=item cache

    enable 'XSLT', cache => 1;

Enables caching of XSLT stylesheets. Defaults to false.

=back

=cut

