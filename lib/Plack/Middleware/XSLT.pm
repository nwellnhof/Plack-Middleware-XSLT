package Plack::Middleware::XSLT;
use strict;
use warnings;

# ABSTRACT: XSLT transformations with Plack

use parent 'Plack::Middleware';

use File::Spec;
use HTTP::Exception ();
use Plack::Response;
use Plack::Util::Accessor qw(cache path parser_options);
use Try::Tiny;
use XML::LibXML 1.62;
use XML::LibXSLT 1.62;

my ($parser, $xslt);

sub call {
    my ($self, $env) = @_;

    my $r     = $self->app->($env);
    my $style = $env->{'xslt.style'};

    return $r if !defined($style) || $style eq '';

    my $path = $self->path;
    $style = File::Spec->catfile($path, $style)
        if defined($path) && !File::Spec->file_name_is_absolute($style);

    my ($status, $headers, $body) = @$r;
    my $doc = $self->_parse_body($body);

    my ($output, $media_type, $encoding) = $self->_xform($style, $doc);

    my $res = Plack::Response->new($status, $headers, $output);
    $res->content_type("$media_type; charset=$encoding");
    $res->content_length(length($output));

    return $res->finalize();
}

sub _xform {
    my ($self, $style, $doc) = @_;

    if (!$xslt) {
        if ($self->cache) {
            require XML::LibXSLT::Cache;
            $xslt = XML::LibXSLT::Cache->new;
        }
        else {
            $xslt = XML::LibXSLT->new;
        }
    }

    my $stylesheet = $xslt->parse_stylesheet_file($style);

    my $result = try {
        $stylesheet->transform($doc) or die("XSLT transform failed: $!");
    }
    catch {
        for my $line (split(/\n/, $_)) {
            HTTP::Exception->throw($1) if $line =~ /^(\d\d\d)(?:\s|\z)/;
        }
        die($_);
    };

    my $output     = $stylesheet->output_as_bytes($result);
    my $media_type = $stylesheet->media_type();
    my $encoding   = $stylesheet->output_encoding();

    return ($output, $media_type, $encoding);
}

sub _parse_body {
    my ($self, $body) = @_;

    if (!$parser) {
        my $options = $self->parser_options;
        $parser = $options
                ? XML::LibXML->new($options)
                : XML::LibXML->new;
    }

    my $doc;

    if (ref($body) eq 'ARRAY') {
        my $xml = join('', @$body);

        $doc = $parser->parse_string($xml);
    }
    else {
        $doc = $parser->parse_fh($body);
    }

    return $doc;
}

sub _cache_hits {
    my $self = shift;

    return $xslt->cache_hits
        if $xslt && $xslt->isa('XML::LibXSLT::Cache');

    return 0;
}

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
variable 'xslt.style'. If this variable is undefined or empty, the response
is not altered. This rather crude mechanism might be enhanced in the future.

The Content-Type header is set according to xsl:output. Content-Length is
adjusted.

=head1 CONFIGURATION

=over 4

=item cache

    enable 'XSLT', cache => 1;

Enables caching of XSLT stylesheets. Defaults to false.

=item path

    enable 'XSLT', path => 'path/to/xsl/files';

Sets a path that will be prepended if xslt.style contains a relative path.
Defaults to the current directory.

=item parser_options

    enable 'XSLT', parser_options => \%options;

Options that will be passed to the XML parser when parsing the input
document. See L<XML::LibXML::Parser/"PARSER OPTIONS">.

=back

=head1 HTTP EXCEPTIONS

If the transform exits via C<<xsl:message terminate="yes">> and the
message contains a line starting with a three-digit HTTP response status
code, a corresponding L<HTTP::Exception> is thrown.

=cut

