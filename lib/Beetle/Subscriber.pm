package Beetle::Subscriber;

use Moose;
use Hash::Merge::Simple qw( merge );
use Beetle::Handler;
use Beetle::Message;
use Beetle::Constants;
extends qw(Beetle::Base::PubSub);

has 'handlers' => (
    default => sub { {} },
    handles => {
        get_handler => 'get',
        has_handler => 'exists',
        set_handler => 'set',
    },
    is     => 'ro',
    isa    => 'HashRef',
    traits => [qw(Hash)],
);

has 'amqp_connections' => (
    default => sub { {} },
    is      => 'ro',
    isa     => 'HashRef',
    traits  => [qw(Hash)],
);

has 'mqs' => (
    default => sub { {} },
    handles => {
        get_mq => 'get',
        has_mq => 'exists',
        set_mq => 'set',
    },
    is     => 'ro',
    isa    => 'HashRef',
    traits => [qw(Hash)],
);

sub listen {
    my ( $self, $messages, $code ) = @_;
    my $exchanges = $self->exchanges_for_messages($messages);
    $self->create_exchanges($exchanges);
    my $queues = $self->queues_for_exchanges($exchanges);
    $self->bind_queues($queues);
    $self->subscribe_queues($queues);
    $code->() if defined $code && ref $code eq 'CODE';
    $self->bunny->listen;
}

sub stop {
    my ($self) = @_;
    $self->bunny->stop;
}

sub register_handler {
    my ( $self, $queues, $options, $handler ) = @_;
    foreach my $queue (@$queues) {
        $self->set_handler(
            $queue => {
                code    => $handler,
                options => $options,
            }
        );
    }
}

sub exchanges_for_messages {
    my ( $self, $messages ) = @_;
    my %exchanges = ();
    foreach my $m (@$messages) {
        my $message = $self->client->get_message($m);
        next unless $message;
        my $exchange = $message->{exchange};
        $exchanges{$exchange} = 1;
    }
    return [ keys %exchanges ];
}

sub queues_for_exchanges {
    my ( $self, $exchanges ) = @_;
    my %queues = ();
    foreach my $e (@$exchanges) {
        my $exchange = $self->client->get_exchange($e);
        next unless $exchange;
        my $q = $exchange->{queues};
        $queues{$_} = 1 for @$q;
    }
    return [ keys %queues ];
}

sub create_exchanges {
    my ( $self, $exchanges ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            foreach my $exchange (@$exchanges) {
                $self->exchange($exchange);
            }
        }
    );
}

sub bind_queues {
    my ( $self, $queues ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            foreach my $queue (@$queues) {
                $self->queue($queue);
            }
        }
    );
}

sub subscribe_queues {
    my ( $self, $queues ) = @_;
    $self->each_server(
        sub {
            my $self = shift;
            foreach my $queue (@$queues) {
                $self->subscribe($queue) if $self->has_handler($queue);
            }
        }
    );
}

sub subscribe {
    my ( $self, $queue_name ) = @_;

    $self->error( sprintf 'no handler for queue %s', $queue_name ) unless $self->has_handler($queue_name);

    my $handler         = $self->get_handler($queue_name);
    my $amqp_queue_name = $self->client->get_queue($queue_name)->{amqp_name};

    my $callback =
      $self->create_subscription_callback( $queue_name, $amqp_queue_name, $handler->{code}, $handler->{options} );

    $self->log->debug( sprintf 'Beetle: subscribing to queue %s with key # on server %s',
        $amqp_queue_name, $self->server );

    eval {
        $self->bunny->subscribe( $queue_name => $callback );    # TODO: <plu> implement this.
    };
    if ($@) {
        $self->error('Beetle: binding multiple handlers for the same queue isn\'t possible');
    }
}

sub create_subscription_callback {
    my ( $self, $queue_name, $amqp_queue_name, $handler, $options ) = @_;
    return sub {
        my ($amqp_message) = @_;
        my $header         = $amqp_message->{header};
        my $body           = $amqp_message->{body}->payload;
        my $deliver        = $amqp_message->{deliver};
        eval {
            my $processor = Beetle::Handler->create( $handler, $options );
            my $message_options = merge $options,
              { server => $self->server, store => $self->client->deduplication_store };
            my $message = Beetle::Message->new(
                config  => $self->config,
                queue   => $amqp_queue_name,
                header  => $header,
                body    => $body,
                deliver => $deliver,
                %$message_options,
            );
            my $result = $message->process($processor);
            if ( grep $_ eq $result, @RECOVER ) {
                sleep 1;
                $self->bunny->recover;
            }
            else {
                $self->bunny->ack( { delivery_tag => $message->deliver->method_frame->delivery_tag } )
                  if $message->_ack;
            }

            # TODO: complete the implementation of reply_to
            return $result;
        };
    };
}

sub bind_queue {
    my ( $self, $queue_name, $creation_keys, $exchange_name, $binding_keys ) = @_;
    $self->bunny->queue_declare( $queue_name => $creation_keys );
    $self->exchange($exchange_name);
    $self->bunny->queue_bind( $queue_name, $exchange_name, $binding_keys->{key} );
}

1;
