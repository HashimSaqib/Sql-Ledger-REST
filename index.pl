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
get '/:client/gl_transaction/:id' => sub {
    my $c      = shift;
    my $id     = $c->param('id');
    my $client = $c->param('client');

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
    my $dbs = $c->dbs($client);

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
        for my $line (@lines) {
            if ( exists $line->{description} ) {
                $line->{accdescription} = delete $line->{description};
            }
            delete $line->{entry_id};
            delete $line->{trans_id};
        }
    }

    my $response = {
        HEADER => {
            id               => $form->{id},
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

get '/:client/gl_transactions' => sub {
    my $c      = shift;
    my $params = $c->req->params->to_hash;
    my $client = $c->param('client');

    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

    my $form = new Form;
    for ( keys %$params ) { $form->{$_} = $params->{$_} if $params->{$_} }
    $form->{category} = 'X';

    GL->transactions( $c->slconfig, $form );

    # Check if the result is undefined, empty, or has no entries
    if (  !defined $form->{GL}
        || ref $form->{GL} ne 'ARRAY'
        || scalar( @{ $form->{GL} } ) == 0 )
    {
        return $c->render(
            status => 404,
            json   => { error => "No transactions found" }
        );
    }

    # Assuming $form->{GL} is an array reference with hash references
    foreach my $transaction ( @{ $form->{GL} } ) {
        delete $transaction->{$_}
          for
          qw(address address1 address2 city country entry_id name name_id zipcode);
    }

    $c->render( status => 200, json => $form->{GL} );
};

post '/:client/gl_transaction' => sub {
    my $c      = shift;
    my $client = $c->param('client');
    my $data   = $c->req->json;

    # Check if the LINES array has at least 2 items
    unless ( @{ $data->{LINES} } >= 2 ) {
        return $c->render(
            status => 400,
            json   => {
                Error => {
                    message => "At least two items are required in LINES.",
                },
            },
        );
    }

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
    my $dbs = $c->dbs($client);

    # Create a new form
    my $form = new Form;

    # Load the input data into the form
    $form->{reference}    = $data->{reference_number};
    $form->{department}   = $data->{department};
    $form->{notes}        = $data->{notes};
    $form->{description}  = $data->{description};
    $form->{curr}         = $data->{currency};
    $form->{exchangerate} = $data->{exchangerate};
    $form->{transdate}    = $data->{transdate};

    my $i            = 1;
    my $total_debit  = 0;
    my $total_credit = 0;
    foreach my $line ( @{ $data->{LINES} } ) {
        $form->{"debit_$i"}     = $line->{debit};
        $form->{"credit_$i"}    = $line->{credit};
        $form->{"accno_$i"}     = $line->{accno};
        $form->{"tax_$i"}       = $line->{tax_account};
        $form->{"taxamount_$i"} = $line->{tax_amount};
        $form->{"cleared_$i"}   = $line->{cleared};

        $total_debit  += $line->{debit};
        $total_credit += $line->{credit};

        $i++;
    }

    if ( $total_debit != $total_credit ) {
        return $c->render(
            status => 400,
            json   => {
                Error => {
                    message =>
                      "The total debit and credit amounts do not match.",
                },
            },
        );
    }

    $form->{rowcount} = $i - 1;    # Count of number of lines

    # Call the function to add the transaction
    my $id = GL->post_transaction( $c->slconfig, $form );

    warn $c->dumper($form);

    # Convert the Form object back into a JSON-like structure
    my $response_json = {
        id               => $form->{id},
        reference_number => $form->{reference},
        department       => $form->{department},
        notes            => $form->{notes},
        description      => $form->{description},
        currency         => $form->{curr},
        exchangerate     => $form->{exchangerate},
        transdate        => $form->{transdate},
        LINES            => []
    };

    for my $i ( 1 .. $form->{rowcount} ) {
        push @{ $response_json->{LINES} },
          {
            debit       => $form->{"debit_$i"},
            credit      => $form->{"credit_$i"},
            accno       => $form->{"accno_$i"},
            tax_account => $form->{"tax_$i"},
            tax_amount  => $form->{"taxamount_$i"},
            cleared     => $form->{"cleared_$i"},
          };
    }

    $c->render(
        status => 201,
        json   => $response_json,
    );
};

app->start;
