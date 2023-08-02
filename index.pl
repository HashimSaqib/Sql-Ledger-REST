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
use DateTime::Format::ISO8601;

my %myconfig = (
    dateformat   => 'yyyy/mm/dd',
    dbdriver     => 'Pg',
    dbhost       => '',
    dbname       => 'ledger28',
    dbpasswd     => '',
    dbport       => '',
    dbuser       => 'postgres',
    numberformat => '1,000.00',
);

helper slconfig => sub { \%myconfig };

# Helper method
helper client_check => sub {
    my ( $c, $client ) = @_;
    unless ( $client eq 'ledger28' ) {
        $c->render(
            status => 404,
            json   => {
                Error => {
                    message => "Client not found.",
                },
            },
        );
        return 0;
    }
    return 1;
};

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

helper validate_date => sub {
    my ( $c, $date ) = @_;
    unless ( $date =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        return $c->render(
            status => 400,
            json   => {
                Error => {
                    message =>
"Invalid date format. Expected ISO 8601 date format (YYYY-MM-DD).",
                },
            },
        );
    }
    return 1;    # return true if the date is valid
};

#Ledger API Calls

# Get Account Trans
get '/:client/acc-trans' => sub {
    my $c      = shift;
    my $params = $c->req->params->to_hash;
    my $client = $c->param('client');
    return unless $c->client_check($client);

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

get '/:client/gl/transactions' => sub {
    my $c      = shift;
    my $client = $c->param('client');
    return unless $c->client_check($client);

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
    my $dbs = $c->dbs($client);

    my $startDate  = $c->param('startDate');
    my $endDate    = $c->param('endDate');
    my $searchText = $c->param('searchText');

    if ($startDate) { $c->validate_date($startDate) or return; }
    if ($endDate)   { $c->validate_date($endDate)   or return; }

    my $query =
'SELECT id, reference, transdate, description, notes, curr, department_id AS department, approved, ts, exchangerate AS exchangeRate, employee_id FROM gl';
    my @query_params;

    my @conditions;
    if ($startDate) {
        if ($endDate) {
            push @conditions, 'transdate BETWEEN ? AND ?';
            push @query_params, $startDate, $endDate;
        }
        else {
            push @conditions,   'transdate = ?';
            push @query_params, $startDate;
        }
    }
    if ($searchText) {
        push @conditions,
          '(description ILIKE ? OR notes ILIKE ? OR reference ILIKE ?)';
        push @query_params, "%$searchText%", "%$searchText%", "%searchText%";
    }

    if (@conditions) {
        $query .= ' WHERE ' . join( ' AND ', @conditions );
    }

    my $ngl_results = $dbs->query( $query, @query_params );
    my @transactions;

    # Loop through the transactions
    while ( my $transaction = $ngl_results->hash ) {

        # Fetch entries for the current transaction
        my $entries_results = $dbs->query(
'SELECT chart.accno, chart.description, acc_trans.amount, acc_trans.source, acc_trans.memo, acc_trans.tax_chart_id, acc_trans.taxamount, acc_trans.fx_transaction, acc_trans.cleared FROM acc_trans JOIN chart ON acc_trans.chart_id = chart.id WHERE acc_trans.trans_id = ?',
            $transaction->{id}
        );
        my @lines;

        # Loop through the entries and push them into the @entries array
        while ( my $line = $entries_results->hash ) {
            my $debit  = $line->{amount} < 0  ? -$line->{amount} : 0;
            my $credit = $line->{amount} >= 0 ? $line->{amount}  : 0;
            push @lines,
              {
                accno         => $line->{accno},
                debit         => $debit,
                credit        => $credit,
                memo          => $line->{memo},
                source        => $line->{source},
                taxAccount    => $line->{tax_chart_id},
                taxAmount     => $line->{taxamount},
                fxTransaction => $line->{fx_transaction},
                cleared       => $line->{cleared},
              };
        }

        # Add the entries to the transaction
        $transaction->{lines} = \@lines;

        # Push the transaction into the @transactions array
        push @transactions, $transaction;
    }

    $c->render( json => \@transactions );
};

#Get An Individual GL transaction
get '/:client/gl/transaction/:id' => sub {
    my $c      = shift;
    my $id     = $c->param('id');
    my $client = $c->param('client');
    return unless $c->client_check($client);

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

            # Create a new hash with only the required fields
            my %new_line;
            $new_line{debit} =
                $line->{amount} > 0
              ? $line->{amount}
              : 0;    # Assuming amount > 0 is debit

            $new_line{credit} =
              $line->{amount} < 0
              ? -$line->{amount}
              : 0;    # Assuming amount < 0 is credit

            $new_line{accno}         = $line->{accno};
            $new_line{taxAccount}    = $line->{tax_chart_id};
            $new_line{taxAmount}     = $line->{taxamount};
            $new_line{cleared}       = $line->{cleared};
            $new_line{memo}          = $line->{memo};
            $new_line{source}        = $line->{source};
            $new_line{fxTransaction} = $line->{fx_transaction};
            $line                    = \%new_line;
        }
    }

    my $response = {
        id           => $form->{id},
        reference    => $form->{reference},
        approved     => $form->{approved},
        ts           => $form->{ts},
        curr         => $form->{curr},
        description  => $form->{description},
        notes        => $form->{notes},
        department   => $form->{department},
        transdate    => $form->{transdate},
        ts           => $form->{ts},
        exchangeRate => $form->{exchangerate},
        employeeId   => $form->{employee_id},
        lines        => \@lines,
    };

    $c->render( status => 200, json => $response );
};

post '/:client/gl/transaction' => sub {
    my $c      = shift;
    my $client = $c->param('client');
    return unless $c->client_check($client);

    my $data = $c->req->json;

    # Check if 'transdate' is present in the data
    unless ( exists $data->{transdate} ) {
        return $c->render(
            status => 400,
            json   => {
                Error => {
                    message => "The 'transdate' field is required.",
                },
            },
        );
    }

    my $transdate = $data->{transdate};

    # Validate 'transdate' format (ISO date format)
    unless ( $transdate =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        return $c->render(
            status => 400,
            json   => {
                Error => {
                    message =>
"Invalid 'transdate' format. Expected ISO 8601 date format (YYYY-MM-DD).",
                },
            },
        );
    }

    # Check if the LINES array has at least 2 items
    unless ( @{ $data->{lines} } >= 2 ) {
        return $c->render(
            status => 400,
            json   => {
                Error => {
                    message => "At least two items are required in LINES.",
                },
            },
        );
    }

    # Check if 'CURR' is present and validate against database if not empty
    if ( exists $data->{currency} && $data->{currency} ne '' ) {
        my $currency = $data->{currency};
        my $dbs      = $c->dbs($client);

        # Check if the 'CURR' exists in the 'curr' column of the database table
        my $result =
          $dbs->query( "SELECT curr FROM curr WHERE curr = ?", $currency );
        unless ( $result->rows ) {
            return $c->render(
                status => 400,
                json   => {
                    Error => {
                        message => "The specified currency does not exist.",
                    },
                },
            );
        }
    }

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
    my $dbs = $c->dbs($client);

    # Create a new form
    my $form = new Form;
    if ( !$data->{department} ) { $data->{department} = 0 }

    # Load the input data into the form
    $form->{reference}   = $data->{reference};
    $form->{department}  = $data->{department};
    $form->{notes}       = $data->{notes};
    $form->{description} = $data->{description};
    $form->{curr}        = $data->{currency};
    $form->{exchangeate} = $data->{exchangeRate};
    $form->{transdate}   = $transdate;

    my $i            = 1;
    my $total_debit  = 0;
    my $total_credit = 0;
    foreach my $line ( @{ $data->{lines} } ) {
        $form->{"debit_$i"}          = $line->{debit};
        $form->{"credit_$i"}         = $line->{credit};
        $form->{"accno_$i"}          = $line->{accno};
        $form->{"tax_$i"}            = $line->{taxAccount};
        $form->{"taxamount_$i"}      = $line->{taxAmount};
        $form->{"cleared_$i"}        = $line->{cleared};
        $form->{"memo_$i"}           = $line->{memo};
        $form->{"source_$i"}         = $line->{source};
        $form->{"fx_transaction_$i"} = $line->{fxTransaction};
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
        id           => $form->{id},
        reference    => $form->{reference},
        department   => $form->{department},
        notes        => $form->{notes},
        description  => $form->{description},
        currency     => $form->{curr},
        exchangeRate => $form->{exchangerate},
        transdate    => $form->{transdate},
        employeeId   => $form->{employee_id},
        lines        => []
    };

    for my $i ( 1 .. $form->{rowcount} ) {
        push @{ $response_json->{lines} },
          {
            debit         => $form->{"debit_$i"},
            credit        => $form->{"credit_$i"},
            accno         => $form->{"accno_$i"},
            taxAccount    => $form->{"tax_$i"},
            taxAmount     => $form->{"taxamount_$i"},
            cleared       => $form->{"cleared_$i"},
            memo          => $form->{"memo_$i"},
            source        => $form->{"source_$i"},
            fxTransaction => $form->{"fx_transaction_$i"},
          };
    }

    $c->render(
        status => 201,
        json   => $response_json,
    );
};

app->start;
