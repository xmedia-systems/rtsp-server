package RTSP::Server::RTPListener;

use Moose;
use namespace::autoclean;

use AnyEvent::Util;
use Socket;
use Socket6;

has 'mount' => (
    is => 'ro',
    isa => 'RTSP::Server::Mount',
    required => 1,
);

has 'stream' => (
    is => 'ro',
    isa => 'RTSP::Server::Mount::Stream',
    required => 1,
);

has 'host' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'addr_family' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'port' => (
    is => 'ro',
    isa => 'Int',
    required => 1,
);

has 'read_size' => (
    is => 'rw',
    isa => 'Int',
    default => 1500,
);

has 'watcher' => (
    is => 'rw',
    clearer => 'clear_watcher',
);

has 'socket' => (
    is => 'rw',
);

has 'connection' => (
    is => 'rw',
);

has 'timer' => (
    is => 'rw',
);

has 'idle' => (
    is => 'rw',
);

sub listen {
    my ($self) = @_;

    # create UDP listener socket
    my($name, $alias, $udp_proto) = AnyEvent::Socket::getprotobyname('udp');
    socket my($sock), $self->addr_family, SOCK_DGRAM, $udp_proto;
    AnyEvent::Util::fh_nonblocking $sock, 1;

    my $addr;
    if ($self->addr_family == AF_INET) {
        $addr = sockaddr_in($self->port, Socket::inet_aton($self->host));
    } elsif ($self->addr_family == AF_INET6) {
        $addr = sockaddr_in6($self->port, Socket6::inet_pton(AF_INET6, $self->host));
    }
    unless (bind $sock, $addr) {
        warn("Error binding UDP listener to port " . $self->port . ": $!");
        return;
    }

    $self->socket($sock);

    my $buf;
    my $read_size = $self->read_size;
    my $w = AnyEvent->io(
        fh => $sock,
        poll => 'r', cb => sub {
            my $sender_addr = recv $sock, $buf, $read_size, 0;

            # TODO: compare $sender_addr to expected addr

            if (! defined $sender_addr) {
                # error receiving UDP packet
                warn("Error receiving RTP data.");
                $self->clear_watcher;
                return;
            }
            if ($buf) {
                $self->idle(0);
            }

            next unless $buf;

            $self->stream->broadcast($buf);
        }
    );

    $self->idle(0);
    my $timeout = AnyEvent->timer (interval => 1, cb => sub {
        $self->idle($self->idle + 1);
        if($self->idle > $self->connection->server->rtp_timeout) {
            my $mount = $self->mount->path;
            $self->connection->debug("Timeout reached for $mount");
            $self->connection->unmount($mount);
            $self->connection->end_rtp_server;
            return;
        }
    });
    $self->timer($timeout);

    $self->watcher($w);

    # TODO: send UDP packet every 30 seconds to keep stateful UDP
    # firewalls open

    return 1;
}

sub close {
    my ($self) = @_;

    $self->clear_watcher;

    if ($self->socket) {
        shutdown $self->socket, 2;
    }
    $self->timer(undef);
}

sub DEMOLISH {
    my ($self) = @_;

    $self->close;
}

__PACKAGE__->meta->make_immutable;
