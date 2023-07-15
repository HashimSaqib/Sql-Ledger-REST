#!/usr/bin/env perl

BEGIN {
    push @INC, '.';
}

use Mojolicious::Lite;
use XML::Hash::XS;
use JSON::XS;
use Data::Dumper;
use Mojo::Util qw(unquote);
use DBI;
use DBIx::Simple;
use XML::Simple;
use Data::Format::Pretty::JSON qw(format_pretty);
use Data::Dumper;
use SL::Form;
use SL::AM;
use SL::CT;
use SL::RP;
use SL::AA;
use SL::IS;
use SL::CA;
use SL::GL;
use Mojo::JSON qw(encode_json);

my %myconfig = (
    dateformat   => 'mm/dd/yy',
    dbdriver     => 'Pg',
    dbhost       => '',
    dbname       => 'ledger28',
    dbpasswd     => '',
    dbport       => '',
    dbuser       => 'postgres',
    numberformat => '1,000.00',
);

helper slconfig => sub { \%myconfig };

helper dbs => sub {
    my ( $c, $dbname ) = @_;
    my $dbs;
    if ($dbname) {
        my $dbh = DBI->connect( "dbi:Pg:dbname=$dbname", 'postgres', '' )
          or die $DBI::errstr;
        $dbs = DBIx::Simple->connect($dbh);
        return $dbs;
    }
    else {
        return $dbs;
    }
};

#Ledger API Calls

#Get An Individual GL transaction
get '/gl_transaction/:id' => sub {
    my $c  = shift;
    my $id = $c->param('id');

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=ledger28";
    my $dbs = $c->dbs('ledger28');

    # Check if the ID exists in the gl table
    my $result = $dbs->select( 'gl', '*', { id => $id } );

    unless ( $result->rows ) {

        # ID not found, return a 404 error with JSON response
        return $c->render(
            status => 404,
            json   => {
                error => {
                    message => "The requested GL transaction was not found."
                }
            }
        );
    }

    # If the ID exists, proceed with the rest of the code
    my $form = new Form;

    $form->{id} = $id;
    GL->transaction( $c->slconfig, $form );

    # Extract the GL array and rename it to "LINES" in the JSON response
    my @lines;
    if ( exists $form->{GL} && ref $form->{GL} eq 'ARRAY' ) {
        @lines = @{ $form->{GL} };
    }

    my $response = {
        HEADER => {
            reference        => $form->{reference},
            approved         => $form->{approved},
            ts               => $form->{ts},
            curr             => $form->{curr},
            description      => $form->{description},
            notes            => $form->{notes},
            department       => $form->{department},
            transdate        => $form->{transdate},
            ts               => $form->{ts},
            batchid          => $form->{batchid},
            batchdescription => $form->{batchdescription},
            onhold           => $form->{onhold},
            exchangerate     => $form->{exchangerate},
            employee_id      => $form->{employee_id},
        },
        LINES => \@lines,
    };

    $c->render( status => 200, json => $response );
};

#Get All GL Transactions
get '/gl_transactions' => sub {
    my $c      = shift;
    my $params = $c->req->params->to_hash;

    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=ledger28";

    my $form = new Form;
    for ( keys %$params ) { $form->{$_} = $params->{$_} if $params->{$_} }
    $form->{category} = 'X';

    GL->transactions( $c->slconfig, $form );
    $c->render( status => 200, json => $form->{GL} );
};

app->start;
