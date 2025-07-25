package LWP::ConnCache;

use strict;

our $VERSION = '6.80';
our $DEBUG;

sub new {
    my($class, %cnf) = @_;

    my $total_capacity = 1;
    if (exists $cnf{total_capacity}) {
        $total_capacity = delete $cnf{total_capacity};
    }
    if (%cnf && $^W) {
	require Carp;
	Carp::carp("Unrecognised options: @{[sort keys %cnf]}")
    }
    my $self = bless { cc_conns => [] }, $class;
    $self->total_capacity($total_capacity);
    $self;
}


sub deposit {
    my($self, $type, $key, $conn) = @_;
    push(@{$self->{cc_conns}}, [$conn, $type, $key, time]);
    $self->enforce_limits($type);
    return;
}


sub withdraw {
    my($self, $type, $key) = @_;
    my $conns = $self->{cc_conns};
    for my $i (0 .. @$conns - 1) {
	my $c = $conns->[$i];
	next unless $c->[1] eq $type && $c->[2] eq $key;
	splice(@$conns, $i, 1);  # remove it
	return $c->[0];
    }
    return undef;
}


sub total_capacity {
    my $self = shift;
    my $old = $self->{cc_limit_total};
    if (@_) {
	$self->{cc_limit_total} = shift;
	$self->enforce_limits;
    }
    $old;
}


sub capacity {
    my $self = shift;
    my $type = shift;
    my $old = $self->{cc_limit}{$type};
    if (@_) {
	$self->{cc_limit}{$type} = shift;
	$self->enforce_limits($type);
    }
    $old;
}


sub enforce_limits {
    my($self, $type) = @_;
    my $conns = $self->{cc_conns};

    my @types = $type ? ($type) : ($self->get_types);
    for $type (@types) {
	next unless $self->{cc_limit};
	my $limit = $self->{cc_limit}{$type};
	next unless defined $limit;
	for my $i (reverse 0 .. @$conns - 1) {
	    next unless $conns->[$i][1] eq $type;
	    if (--$limit < 0) {
		$self->dropping(splice(@$conns, $i, 1), "$type capacity exceeded");
	    }
	}
    }

    if (defined(my $total = $self->{cc_limit_total})) {
	while (@$conns > $total) {
	    $self->dropping(shift(@$conns), "Total capacity exceeded");
	}
    }
}


sub dropping {
    my($self, $c, $reason) = @_;
    print "DROPPING @$c [$reason]\n" if $DEBUG;
}


sub drop {
    my($self, $checker, $reason) = @_;
    if (ref($checker) ne "CODE") {
	# make it so
	if (!defined $checker) {
	    $checker = sub { 1 };  # drop all of them
	}
	elsif (_looks_like_number($checker)) {
	    my $age_limit = $checker;
	    my $time_limit = time - $age_limit;
	    $reason ||= "older than $age_limit";
	    $checker = sub { $_[3] < $time_limit };
	}
	else {
	    my $type = $checker;
	    $reason ||= "drop $type";
	    $checker = sub { $_[1] eq $type };  # match on type
	}
    }
    $reason ||= "drop";

    local $SIG{__DIE__};  # don't interfere with eval below
    local $@;
    my @c;
    for (@{$self->{cc_conns}}) {
	my $drop;
	eval {
	    if (&$checker(@$_)) {
		$self->dropping($_, $reason);
		$drop++;
	    }
	};
	push(@c, $_) unless $drop;
    }
    @{$self->{cc_conns}} = @c;
}


sub prune {
    my $self = shift;
    $self->drop(sub { !shift->ping }, "ping");
}


sub get_types {
    my $self = shift;
    my %t;
    $t{$_->[1]}++ for @{$self->{cc_conns}};
    return keys %t;
}


sub get_connections {
    my($self, $type) = @_;
    my @c;
    for (@{$self->{cc_conns}}) {
	push(@c, $_->[0]) if !$type || ($type && $type eq $_->[1]);
    }
    @c;
}


sub _looks_like_number {
    $_[0] =~ /^([+-]?)(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?$/;
}

1;


__END__

=pod

=head1 NAME

LWP::ConnCache - Connection cache manager

=head1 NOTE

This module is experimental.  Details of its interface is likely to
change in the future.

=head1 SYNOPSIS

 use LWP::ConnCache;
 my $cache = LWP::ConnCache->new;
 $cache->deposit($type, $key, $sock);
 $sock = $cache->withdraw($type, $key);

=head1 DESCRIPTION

The C<LWP::ConnCache> class is the standard connection cache manager
for L<LWP::UserAgent>.

=head1 METHODS

The following basic methods are provided:

=head2 new

    my $cache = LWP::ConnCache->new( %options )

This method constructs a new L<LWP::ConnCache> object.  The only
option currently accepted is C<total_capacity>.  If specified it
initializes the L<LWP::ConnCache/total_capacity> option. It defaults to C<1>.

=head2 total_capacity

    my $cap = $cache->total_capacity;
    $cache->total_capacity(0); # drop all immediately
    $cache->total_capacity(undef); # no limit
    $cache->total_capacity($number);

Get/sets the number of connection that will be cached.  Connections
will start to be dropped when this limit is reached.  If set to C<0>,
then all connections are immediately dropped.  If set to C<undef>,
then there is no limit.

=head2 capacity

    my $http_capacity = $cache->capacity('http');
    $cache->capacity('http', 2 );

Get/set a limit for the number of connections of the specified type
that can be cached.  The first parameter is a short string like
C<"http"> or C<"ftp">.

=head2 drop

    $cache->drop(); # Drop ALL connections
    # which is just a synonym for:
    $cache->drop(sub{1}); # Drop ALL connections
    # drop all connections older than 22 seconds and add a reason for it!
    $cache->drop(22, "Older than 22 secs dropped");
    # which is just a synonym for:
    $cache->drop(sub {
        my ($conn, $type, $key, $deposit_time) = @_;
        if ($deposit_time < 22) {
            # true values drop the connection
            return 1;
        }
        # false values don't drop the connection
        return 0;
    }, "Older than 22 secs dropped" );

Drop connections by some criteria.  The $checker argument is a
subroutine that is called for each connection.  If the routine returns
a TRUE value then the connection is dropped.  The routine is called
with C<($conn, $type, $key, $deposit_time)> as arguments.

Shortcuts: If the C<$checker> argument is absent (or C<undef>) all cached
connections are dropped.  If the $checker is a number then all
connections untouched that the given number of seconds or more are
dropped.  If $checker is a string then all connections of the given
type are dropped.

The C<reason> is passed on to the L<LWP::ConnCache/dropped> method.

=head2 prune

    $cache->prune();

Calling this method will drop all connections that are dead.  This is
tested by calling the L<LWP::ConnCache/ping> method on the connections. If
the L<LWP::ConnCache/ping> method exists and returns a false value, then the
connection is dropped.

=head2 get_types

    my @types = $cache->get_types();

This returns all the C<type> fields used for the currently cached
connections.

=head2 get_connections

    my @conns = $cache->get_connections(); # all connections
    my @conns = $cache->get_connections('http'); # connections for http

This returns all connection objects of the specified type.  If no type
is specified then all connections are returned.  In scalar context the
number of cached connections of the specified type is returned.

=head1 PROTOCOL METHODS

The following methods are called by low-level protocol modules to
try to save away connections and to get them back.

=head2 deposit

    $cache->deposit($type, $key, $conn);

This method adds a new connection to the cache.  As a result, other
already cached connections might be dropped.  Multiple connections with
the same type/key might be added.

=head2 withdraw

    my $conn = $cache->withdraw($type, $key);

This method tries to fetch back a connection that was previously
deposited.  If no cached connection with the specified $type/$key is
found, then C<undef> is returned.  There is not guarantee that a
deposited connection can be withdrawn, as the cache manger is free to
drop connections at any time.

=head1 INTERNAL METHODS

The following methods are called internally.  Subclasses might want to
override them.

=head2 enforce_limits

    $conn->enforce_limits([$type])

This method is called with after a new connection is added (deposited)
in the cache or capacity limits are adjusted.  The default
implementation drops connections until the specified capacity limits
are not exceeded.

=head2 dropping

    $conn->dropping($conn_record, $reason)

This method is called when a connection is dropped.  The record
belonging to the dropped connection is passed as the first argument
and a string describing the reason for the drop is passed as the
second argument.  The default implementation makes some noise if the
C<$LWP::ConnCache::DEBUG> variable is set and nothing more.

=head1 SUBCLASSING

For specialized cache policy it makes sense to subclass
C<LWP::ConnCache> and perhaps override the L<LWP::ConnCache/deposit>,
L<LWP::ConnCache/enforce_limits>, and L<LWP::ConnCache/dropping> methods.

The object itself is a hash.  Keys prefixed with C<cc_> are reserved
for the base class.

=head1 SEE ALSO

L<LWP::UserAgent>

=head1 COPYRIGHT

Copyright 2001 Gisle Aas.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
