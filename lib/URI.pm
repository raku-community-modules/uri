unit class URI;

use IETF::RFC_Grammar;
use IETF::RFC_Grammar::URI;
use URI::Escape;
need URI::DefaultPort;

class X::URI::Invalid is Exception {
    has $.source;
    method message { "Could not parse URI: $!source" }
}

our subset Scheme of Str
    where /^ [
           ''
        || <IETF::RFC_Grammar::URI::scheme>
    ] $/;
our subset Userinfo of Str
    where /^ [
           ''
        || <IETF::RFC_Grammar::URI::userinfo>
    ] $/;
our subset Host of Str
    where /^ [
           ''
        || <IETF::RFC_Grammar::URI::host>
    ] $/;
our subset Port of UInt;

class X::URI::Authority::Invalid is X::URI::Invalid {
    has $.before;
    method message {
        "Could not parse URI authority ($.source)."
        ~ $!before ?? " Did you forget to set .host before .$!before?" !! ''
    }
}

class Authority {
    has Userinfo $.userinfo is rw = '';
    has Host $.host is required;
    has Port $.port is rw;

    multi method new(Authority:U: IETF::RFC_Grammar:D $grammar, Str:D $authority) {
        $grammar.parse($authority, rule => 'authority');
        if not $grammar.parse_result {
            X::URI::Authority::Invalid.new(source => $authority).throw;
        }

        self.new($grammar.parse_result);
    }

    multi method new(Authority:U: Match:D $auth) {
        my Str $userinfo = do with $auth<userinfo> { .Str } else { '' }
        my Str $host     = "$auth<host>".lc;
        my UInt $port    = do with $auth<port> { .Int } else { Nil }

        self.new(:$userinfo, :$host, :$port);
    }

    multi method gist(Authority:D:) returns Str {
        my $authority = '';
        $authority ~= "$!userinfo@" if $!userinfo;
        $authority ~= $!host;
        $authority ~= ":$!port" if $!port;
        $authority;
    }

    multi method Str(Authority:D:) returns Str { $.gist }
}

# Because Path is limited in form based on factors outside of it, it doesn't
# actually provide any validation within itself. This type is immutable. The URI
# class is responsible for performing the necessary validations.
class Path {
    has Str $.path;
    has @.segments;

    my @rules = <
        path-abempty
        path-absolute
        path-noscheme
        path-rootless
        path-empty
    >;

    multi method new(Path:U: Match:D $comp) {
        my $path-type = @rules.first({ $comp{ $_ }.defined });
        my $path = $comp{ $path-type };

        my @segments := $path<segment>.list.map({.Str}).list || ('',);
        if my $first_chunk = $path<segment-nz-nc> || $path<segment-nz> {
            @segments := ($first_chunk, |@segments);
        }
        if @segments.elems == 0 {
            @segments := ('',);
        }

        $path = "$path";

        self.new(:$path, :@segments);
    }

    submethod BUILD(:$!path = '', :@segments) {
        @!segments := @segments.List;
    }

    multi method gist(Path:D:) returns Str { $!path }
    multi method Str(Path:D:)  returns Str { $!path }
}

class Query does Positional does Associative does Iterable {
    our subset ValidQuery of Str
        where /^ <IETF::RFC_Grammar::URI::query> $/;

    our enum HashFormat <None Mixed Singles Lists>;

    has HashFormat $.hash-format is rw;
    has ValidQuery $!query;
    has Pair @!query-form;

    multi method new(Str() $query) {
        self.new(:$query);
    }

    submethod BUILD(:$!query, :@!query-form, :$!hash-format = Lists) {
        die "When calling URI::Query.new set either :query or :query-form, but not both."
            if @!query-form and $!query;

        @!query-form = split-query($!query) if $!query;
    }

    method !value-for($key) {
        # TODO Is there a better way to make this list immutable than to use a
        # Proxy container?
        my $l = @!query-form.grep({ .key eq $key }).map({
            my $v = .value;
            Proxy.new(
                FETCH => method () { $v },
                STORE => method ($n) { X::Assignment::RO.new.throw },
            );
        }).List;

        given $!hash-format {
            when Mixed   { $l.elems == 1 ?? $l[0] !! $l }
            when Singles { $l.first(:end) }
            default      { $l }
        }
    }

    method of() { Pair }
    method iterator(Query:D:) { @!query-form.iterator }

    # positional context
    method AT-POS(Query:D: $i)     { @!query-form[$i] }
    method EXISTS-POS(Query:D: $i) { @!query-form[$i]:exists }
    method ASSIGN-POS(Query:D: $i, Pair $p) {
        $!query = Nil;
        @!query-form[$i] = $p;
    }
    method DELETE-POS(Query:D: $i) {
        $!query = Nil;
        @!query-form[$i]:delete
    }

    # associative context
    method AT-KEY(Query:D: $k)     { self!value-for($k) }
    method EXISTS-KEY(Query:D: $k) { @!query-form.first({ .key eq $k }).defined }
    method ASSIGN-KEY(Query:D: $k, $value) {
        $!query = Nil;
        @!query-form .= grep({ .key ne $k });

        given $!hash-format {
            when Singles {
                @!query-form.push: $k => $value;
            }
            default {
                @!query-form.append: $value.list.map({ $k => $^v });
            }
        }

        $value
    }
    method DELETE-KEY(Query:D: $k) {
        $!query = Nil;
        my $r = self!value-for($k);
        my @ps = @!query-form .= grep({ .key ne $k });
        $r;
    }

    # Hash-like readers
    method values(Query:D:) { @!query-form».value }
    method kv(Query:D:) { @!query-form».kv.flat }
    method pairs(Query:D:) { @!query-form }

    # Array-like manipulators
    method pop(Query:D:) { $!query = Nil; @!query-form.pop }
    method push(Query:D: |c) { $!query = Nil; @!query-form.push: |c }
    method append(Query:D: |c) { $!query = Nil; @!query-form.append: |c }
    method shift(Query:D:) { $!query = Nil; @!query-form.shift }
    method unshift(Query:D: |c) { $!query = Nil; @!query-form.unshift: |c }
    method prepend(Query:D: |c) { $!query = Nil; @!query-form.prepend: |c }
    method splice(Query:D: |c) { $!query = Nil; @!query-form.splice: |c }

    # Array-like readers
    method elems(Query:D:) { @!query-form.elems }
    method end(Query:D:) { @!query-form.end }

    method Bool(Query:D: |c) { @!query-form.Bool }
    method Int(Query:D: |c) { @!query-form.Int }
    method Numeric(Query:D: |c) { @!query-form.Numeric }
    method Capture(Query:D: |c) { @!query-form.Capture }

    multi method query(Query:D:) {
        return $!query with $!query;
        $!query = @!query-form.grep({ .defined }).map({
            if .value eqv True {
                uri-escape(.key)
            }
            else {
                "{uri-escape(.key)}={uri-escape(.value)}"
            }
        }).join('&');
    }

    multi method query(Query:D: Str() $new) {
        $!query = $new;
        @!query-form = split-query($!query) if $!query;
        $!query;
    }

    multi method query-form(Query:D:) { @!query-form }

    multi method query-form(Query:D: *@new, *%new) {
        $!query = Nil;
        @!query-form = flat %new, @new;
    }

    # string context
    multi method gist(Query:D:) returns Str { $.query }
    multi method Str(Query:D:) returns Str { $.gist }

}

our subset Fragment of Str
    where /^ <IETF::RFC_Grammar::URI::fragment> $/;

has $.grammar;
has Bool $.match-prefix = False;
has Path $.path = Path.new;
has Scheme $.scheme = '';
has Authority $.authority is rw;
has Query $.query = Query.new('');
has Fragment $.fragment is rw = '';
has $!uri;  # use of this now deprecated

method parse(URI:D: Str() $str, Bool :$match-prefix = False) {

    # clear string before parsing
    my Str $c_str = $str;
    $c_str .= subst(/^ \s* ['<' | '"'] /, '');
    $c_str .= subst(/ ['>' | '"'] \s* $/, '');

    $!scheme    = '';
    $!authority = Nil;
    $!path      = Path.new;
    $!query.query('');
    $!fragment  = '';
    $!uri = Mu;

    if ($!match-prefix or $match-prefix) {
        $!grammar.subparse($c_str);
    }
    else {
        $!grammar.parse($c_str);
    }

    # hacky but for the time being an improvement
    if (not $!grammar.parse_result) {
        X::URI::Invalid.new(source => $str).throw
    }

    # now deprecated
    $!uri = $!grammar.parse_result;

    my $comp_container = $!grammar.parse_result<URI-reference><URI> ||
        $!grammar.parse_result<URI-reference><relative-ref>;

    $!scheme = .lc with $comp_container<scheme>;
    $!query.query(.Str) with $comp_container<query>;
    $!fragment = .lc with $comp_container<fragment>;
    $comp_container = $comp_container<hier-part> || $comp_container<relative-part>;

    with $comp_container<authority> -> $auth {
        $!authority = Authority.new($auth);
    }

    $!path = Path.new($comp_container);
}

our sub split-query(
    Str() $query,
    Query::HashFormat :$hash-format = Query::None,
) {

    my @query-form = gather for $query.split(/<[&;]>/) {
        # when the query component contains abc=123 form
        when /'='/ {
            my ($k, $v) = .split('=', 2).map(&uri-unescape);
            take $k => $v;
        }

        # or if the component contains just abc
        default {
            take $_ => True;
        }
    }

    given $hash-format {
        when Query::Mixed {
            my %query-form;

            for @query-form -> $qp {
                if %query-form{ $qp.key }:exists {
                    if %query-form{ $qp.key } ~~ Array {
                        %query-form{ $qp.key }.push: $qp.value;
                    }
                    else {
                        %query-form{ $qp.key } = [
                            %query-form{ $qp.key },
                            $qp.value,
                        ];
                    }
                }
                else {
                    %query-form{ $qp.key } = $qp.value;
                }
            }

            return %query-form;
        }

        when Query::Singles {
            return %(@query-form);
        }

        when Query::Lists {
            my %query-form;
            %query-form{ .key }.push: .value for @query-form;
            return %query-form;
        }

        default {
            return @query-form;
        }
    }
}

# artifact form
our sub split_query(|c) { split-query(|c) }

# deprecated old call for parse
method init ($str) {
    warn "init method now deprecated in favor of parse method";
    $.parse($str);
}

# new can pass alternate grammars some day ...
submethod BUILD(:$match-prefix) {
    $!match-prefix = ? $match-prefix;
    $!grammar = IETF::RFC_Grammar.new('rfc3986');
}

multi method new(URI:U: $uri, Bool :$match-prefix) {
    my $obj = self.bless(:$match-prefix);

    $obj.parse($uri) if $uri.defined;
    $obj;
}

multi method new(URI:U: :$uri, Bool :$match-prefix) {
    self.new($uri, :$match-prefix);
}

method has-scheme(URI:D:) returns Bool:D {
    $!scheme.chars > 0;
}
method has-authority(URI:D:) returns Bool:D {
    $!authority.defined;
}

my regex path-authority {
    [ $<path-abempty> = <IETF::RFC_Grammar::URI::path-abempty> ]
}
my regex path-scheme {
    [   $<path-absolute> = <IETF::RFC_Grammar::URI::path-absolute>
    |   $<path-rootless> = <IETF::RFC_Grammar::URI::path-rootless>
    |   $<path-empty>    = <IETF::RFC_Grammar::URI::path-empty>
    ]
}
my regex path-plain {
    [   $<path-absolute> = <IETF::RFC_Grammar::URI::path-absolute>
    |   $<path-noscheme> = <IETF::RFC_Grammar::URI::path-noscheme>
    |   $<path-empty>    = <IETF::RFC_Grammar::URI::path-empty>
    ]
}

method !check-path(
    :$has-authority = $.has-authority,
    :$has-scheme    = $.has-scheme,
    :$path          = $.path,
    :$source        = $.gist,
) {
    my &path-regex := $has-authority ?? &path-authority
                   !! $has-scheme    ?? &path-scheme
                   !!                   &path-plain
                   ;

    if $path ~~ &path-regex -> $comp {
        return $comp;
    }
    else {
        X::URI::Invalid.new(:$source).throw
    }
}

multi method scheme(URI:D:) returns Scheme:D { $!scheme }
multi method scheme(URI:D: Str() $scheme) returns Scheme:D {
    self!check-path(:has-scheme, :source(self!gister(:$scheme)));
    $!scheme = $scheme;
}

multi method userinfo(URI:D:) returns Userinfo {
    return .userinfo with $!authority;
    Nil;
}

multi method userinfo(URI:D: Str() $new) returns Userinfo {
    with $!authority {
        .userinfo = $new;
    }
    else {
        X::URI::Authority::Invalid.new(
            before => 'userinfo',
            source => "$new@",
        ).throw
    }
}

multi method host(URI:D:) returns Host {
    return .host with $!authority;
    Nil;
}

multi method host(URI:D: Nil) returns Host {
    with $!authority {
        self!check-path(:!has-authority,
            source => self!gister(authority => ''),
        );

        $!authority = Nil;
    }
}

multi method host(URI:D: Str() $new) returns Host {
    with $!authority {
        .host = $new;
    }
    else {
        self!check-path(:has-authority,
            source => self!gister(authority => $new),
        );

        $!authority .= new(host => $new);
        $!authority.host;
    }
}

method default-port(URI:D:) returns Port {
    URI::DefaultPort.scheme-port($.scheme)
}
method default_port(URI:D:) returns Port { $.default-port } # artifact form

multi method _port(URI:D:) returns Port {
    return .port with $!authority;
    Nil;
}

multi method _port(URI:D: Nil) returns Port {
    .port = Nil with $!authority;
    Nil;
}

multi method _port(URI:D: Int() $new) returns Port {
    with $!authority {
        .port = $new;
    }
    else {
        X::URI::Authority::Invalid.new(
            before => 'port',
            source => ":$new",
        ).throw
    }
}


multi method port(URI:D:) returns Port { $._port // $.default-port }

multi method port(URI:D: |c) returns Port { self._port(|c) }

multi method authority(URI:D:) returns Authority {
    $!authority;
}

multi method authority(URI:D: Nil) returns Authority {
    with $!authority {
        self!check-path(:!has-authority,
            source => self!gister(authority => ''),
        );
    }
    $!authority = Nil;
}

multi method authority(URI:D: Authority:D $new) {
    without $!authority {
        self!check-path(:has-authority,
            source => self!gister(authority => ~$new),
        );
    }
    $!authority = $new;
}

multi method authority(URI:D: Str() $authority) returns Authority:D {
    without $!authority {
        self!check-path(:has-authority,
            source => self!gister(authority => $authority),
        );
    }
    $!authority = Authority.new($!grammar, $authority);
}

multi method path(URI:D:) returns Path:D { $!path }

multi method path(URI:D: Str() $path) {
    my $comp = self!check-path(:$path,
        source => self!gister(path => $path),
    );

    $!path = Path.new($comp);
}

multi method segments(URI:D:) { $!path.segments }

my $warn-deprecate-abs-rel = q:to/WARN-END/;
    The absolute and relative methods are artifacts carried over from an old
    version of the p6 module.  The perl 5 module does not provide such
    functionality.  The Ruby equivalent just checks for the presence or
    absence of a scheme.  The URI rfc does identify absolute URIs and
    absolute URI paths and these methods somewhat confused the two.  Their
    functionality at the URI level is no longer seen as needed and is
    being removed.
WARN-END

method absolute {
    warn "deprecated -\n$warn-deprecate-abs-rel";
    return Bool.new;
}

method relative {
    warn "deprecated -\n$warn-deprecate-abs-rel";
    return Bool.new;
}

multi method query(URI:D:) { $!query }

multi method query(URI:D: Str() $new) {
    $!query.query($new);
    $!query
}

multi method query(URI:D: *@new) {
    $!query.query-form(@new)
}

multi method query-form(URI:D:) {
    warn 'query-form is deprecated, use query instead';
    $!query
}

multi method query-form(URI:D: |c) {
    warn 'query-form is deprecated, use query instead';
    $!query.query-form(|c)
}

method query_form {
    warn 'query_form is deprecated, use query intead';
    $.query
}

method path-query(URI:D:) {
    $.query ?? "$.path?$.query" !! $.path
}

method path_query { $.path-query } #artifact form

multi method fragment(URI:D:) { return-rw $!fragment }
multi method fragment(URI:D: $new) { $!fragment = $new }

method frag(URI:D:) { $.fragment }

method !gister(
    :$scheme = $.scheme,
    :$authority = $.authority,
    :$path = $.path,
    :$query = $.query,
    :$fragment = $.fragment,
) {
    my Str $s;
    $s ~= $scheme if $scheme;
    $s ~= '://' ~ $authority if $authority;
    $s ~= $path;
    $s ~= '?' ~ $query if $query;
    $s ~= '#' ~ $fragment if $fragment;
    $s;
}

multi method gist(URI:D:) { self!gister }
multi method Str(URI:D:) { $.gist }

# chunks now strongly deprecated
# it's segments in p5 URI and segment is part of rfc so no more chunks soon!
method chunks {
    warn "chunks attribute now deprecated in favor of segments";
    $!path.segments;
}

method uri {
    warn "uri attribute now deprecated in favor of .grammar.parse_result";
    $!uri;
}

=begin pod

=head1 NAME

URI — Uniform Resource Identifiers

=head1 SYNOPSIS

    use URI;
    my $u = URI.new('http://example.com/foo/bar?tag=woow#bla');

    # Look at the parts
    say $u.scheme;     #> http
    say $u.authority;  #> example.com
    say $u.host;       #> example.com
    say $u.port;       #> 80
    say $u.path;       #> /foo/bar
    say $u.query;      #> tag=woow
    say $u.query<tag>; #> woow
    say $u.fragment;   #> bla

    # Modify the parts
    $u.scheme('http');


    # something p5 URI without grammar could not easily do !
    my $host-in-grammar =
        $u.grammar.parse-result<URI-reference><URI><hier-part><authority><host>;
    if $host-in-grammar<reg-name> {
        say 'Host looks like registered domain name - approved!';
    }
    else {
        say 'Sorry we do not take ip address hosts at this time.';
        say 'Please use registered domain name!';
    }

    {
        # require whole string matches URI and throw exception otherwise ..
        my $u_v = URI.new('http://?#?#');
        CATCH { when X::URI::Invalid { ... } }
    }

    my $u_pfx = URI.new('http://example.com } function(var mm){', :match-prefix);

=end pod


# vim:ft=perl6
