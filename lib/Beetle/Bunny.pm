package Beetle::Bunny;

use Moose;
use namespace::clean -except => 'meta';
use AnyEvent;
use Coro;
use Net::RabbitFoot;
use Data::Dumper;
extends qw(Beetle::Base);

=head1 NAME

Beetle::Bunny - RabbitMQ adaptor

=head1 DESCRIPTION

This is the adaptor to L<Net::RabbitFoot>. Its interface is similar to the
Ruby AMQP client called C<< bunny >>: http://github.com/celldee/bunny
So the Beetle code using this adaptor can be closer to the Ruby Beetle
implementation.

=cut

has 'host' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has 'port' => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
);

has 'anyevent_condvar' => (
    is  => 'rw',
    isa => 'Any',
);

has '_mq' => (
    isa        => 'Any',
    lazy_build => 1,
    handles    => { _open_channel => 'open_channel', },
);

has '_channel' => (
    default => sub { shift->_open_channel },
    handles => {
        _ack              => 'ack',
        _close            => 'close',
        _bind_queue       => 'bind_queue',
        _consume          => 'consume',
        _get              => 'get',
        _declare_exchange => 'declare_exchange',
        _declare_queue    => 'declare_queue',
        _publish          => 'publish',
        _purge_queue      => 'purge_queue',
        _recover          => 'recover',
    },
    isa  => 'Any',
    lazy => 1,
);

has '_command_history' => (
    default => sub { return []; },
    handles => {
        add_command_history => 'push',
        get_command_history => 'elements',
    },
    is     => 'ro',
    isa    => 'ArrayRef',
    traits => [qw(Array)],
);

has '_replay' => (
    default => 0,
    is      => 'rw',
    isa     => 'Bool',
);

has '_subscriptions' => (
    default => sub { return {}; },
    handles => {
        set_subscription => 'set',
        has_subscription => 'exists'
    },
    is     => 'ro',
    isa    => 'HashRef',
    traits => [qw(Hash)],
);

{
    no warnings 'redefine';

    # TODO: <plu> talk to author of AnyEvent::RabbitMQ how to fix this properly
    *AnyEvent::RabbitMQ::Channel::DESTROY = sub { };
    *AnyEvent::RabbitMQ::DESTROY          = sub { };

    # TODO: <plu> remove this once my patch got accepted
    *AnyEvent::RabbitMQ::Channel::_header = sub {    ## no critic
        my ( $self, $args, $body, ) = @_;

        $args->{weight} ||= 0;

        $self->{connection}->_push_write(
            Net::AMQP::Frame::Header->new(
                weight       => $args->{weight},
                body_size    => length($body),
                header_frame => Net::AMQP::Protocol::Basic::ContentHeader->new(
                    content_type     => 'application/octet-stream',
                    content_encoding => '',
                    headers          => {},
                    delivery_mode    => 1,
                    priority         => 0,
                    correlation_id   => '',

                    # reply_to         => '',
                    expiration => '',
                    message_id => '',
                    timestamp  => time,
                    type       => '',
                    user_id    => '',
                    app_id     => '',
                    cluster_id => '',
                    %$args,
                ),
            ),
            $self->{id},
        );

        return $self;
    };
}

sub ack {
    my ( $self, $options ) = @_;
    $options ||= {};
    $self->_ack(%$options);
}

sub exchange_declare {
    my $self = shift;
    my ( $exchange, $options ) = @_;
    $self->add_command_history( { exchange_declare => \@_ } ) unless $self->_replay;
    $options ||= {};
    $self->log->debug( sprintf 'Declaring exchange with options: %s', Dumper $options);
    $self->_declare_exchange(
        exchange => $exchange,
        no_ack   => 0,
        %$options
    );
}

sub listen {
    my ($self) = @_;
    my $c = AnyEvent->condvar;
    $self->anyevent_condvar($c);

    # Run the event loop forever
    $c->recv;
}

sub publish {
    my ( $self, $exchange_name, $message_name, $data, $header ) = @_;
    $header ||= {};
    my %data = (
        body        => $data,
        exchange    => $exchange_name,
        routing_key => $message_name,
        header      => $header,
        no_ack      => 0,
    );
    $self->log->debug( sprintf 'Publishing message %s on exchange %s using data: %s',
        $message_name, $exchange_name, Dumper \%data );
    $self->_publish(%data);
}

sub purge {
    my ( $self, $queue, $options ) = @_;
    $options ||= {};
    $self->_purge_queue( queue => $queue, %$options );
}

sub recover {
    my ( $self, $options ) = @_;
    $options ||= {};
    $self->_recover( requeue => 1, %$options );
}

sub queue_declare {
    my $self = shift;
    my ( $queue, $options ) = @_;
    $self->add_command_history( { queue_declare => \@_ } ) unless $self->_replay;
    $self->log->debug( sprintf 'Declaring queue with options: %s', Dumper $options);
    $self->_declare_queue(
        no_ack => 0,
        queue  => $queue,
        %$options
    );
}

sub queue_bind {
    my $self = shift;
    my ( $queue, $exchange, $routing_key ) = @_;
    $self->add_command_history( { queue_bind => \@_ } ) unless $self->_replay;
    $self->log->debug( sprintf 'Binding to queue %s on exchange %s using routing key %s',
        $queue, $exchange, $routing_key );
    $self->_bind_queue(
        exchange    => $exchange,
        queue       => $queue,
        routing_key => $routing_key,
        no_ack      => 0,
    );
}

sub stop {
    my ($self) = @_;
    eval { $self->anyevent_condvar->send };
    exit(1) if $@;
}

sub subscribe {
    my $self = shift;
    my ( $queue, $callback ) = @_;
    $self->add_command_history( { subscribe => \@_ } ) unless $self->_replay;
    my $has_subscription = $self->has_subscription($queue);
    die "Already subscribed to queue $queue" if $has_subscription;
    $self->set_subscription( $queue => 1 );
    $self->log->debug( sprintf 'Subscribing to queue %s', $queue );
    $self->_consume(
        on_consume => $callback,
        queue      => $queue,
        no_ack     => 0,
    );
}

sub _reconnect {
    my ($self) = @_;
    $self->log->error( sprintf 'Lost connection to %s:%s, trying to reconnect', $self->host, $self->port );
    $self->{_mq}            = $self->_build__mq;
    $self->{_channel}       = $self->_open_channel;
    $self->{_subscriptions} = {};
    $self->_replay_command_history;
    return 1;
}

sub _replay_command_history {
    my ($self) = @_;
    foreach my $command ( $self->get_command_history ) {
        my ( $method, $args ) = %$command;
        $self->_replay(1);
        $self->$method(@$args);
        $self->_replay(0);
    }
}

sub _build__mq {
    my ($self) = @_;
    my $rf;
    my $attempts = 0;
    do {
        eval {
            $rf = Net::RabbitFoot->new( verbose => $self->config->verbose );
            $rf->connect(
                on_close => unblock_sub {
                    $self->_reconnect;
                },
                host  => $self->host,
                port  => $self->port,
                user  => $self->config->user,
                pass  => $self->config->password,
                vhost => $self->config->vhost,
            );
        };
        if ($@) {
            $self->log->error($@) if $attempts++ % 60 == 0;
            sleep(1);
        }
    } while $@;
    $self->log->debug( sprintf 'Successfully connected to %s:%s', $self->host, $self->port );
    return $rf;
}

__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

See L<Beetle>.

=head1 COPYRIGHT AND LICENSE

See L<Beetle>.

=cut

1;
