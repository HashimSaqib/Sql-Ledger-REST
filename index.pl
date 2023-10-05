#!/usr/bin/env perl

BEGIN {
    push @INC, '.';
}

use Mojolicious::Lite;
use XML::Hash::XS;
use Data::Dumper;
use Mojo::Util qw(unquote);
use DBI;
use DBIx::Simple;
use XML::Simple;
use Data::Dumper;
use SL::Form;
use SL::AM;
use SL::CT;
use SL::RP;
use SL::AA;
use SL::IS;
use SL::CA;
use SL::GL;
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

my $r = app->routes;

my $api = $r->under('/api/client');

$api->get(
    '/:client/gl/transactions' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        return unless $c->client_check($client);

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Searching Parameters
        my $startDate   = $c->param('startDate');
        my $endDate     = $c->param('endDate');
        my $description = $c->param('description');
        my $notes       = $c->param('notes');
        my $reference   = $c->param('reference');
        my $accno       = $c->param('accno');

        # Pagination Parameters
        my $limit = $c->param('limit') || 20;        # Default value is 20
        my $page  = $c->param('page')  || 1;         # Default value is 1
        my $sort  = $c->param('sort')  || 'DESC';    # Default value is DESC

        # Validate the Parameters
        unless ( $limit =~ /^\d+$/
            && $page =~ /^\d+$/
            && ( $sort eq 'ASC' || $sort eq 'DESC' ) )
        {
            return $c->render(
                status => 400,
                json   => {
                    error => {
                        message => "Invalid pagination or sort parameters."
                    }
                }
            );

        }

        my $offset = ( $page - 1 ) * $limit;

        # Validate Date
        if ($startDate) { $c->validate_date($startDate) or return; }
        if ($endDate)   { $c->validate_date($endDate)   or return; }

        my $query =
'SELECT id, reference, transdate, description, notes, curr, department_id AS department, approved, ts, exchangerate AS exchangeRate, employee_id FROM gl';
        my @query_params;

        my @conditions;
        if ( $startDate && $endDate ) {
            push @conditions, 'transdate BETWEEN ? AND ?';
            push @query_params, $startDate, $endDate;
        }
        elsif ($startDate) {
            push @conditions,   'transdate = ?';
            push @query_params, $startDate;
        }

        if ($description) {
            push @conditions,   'description ILIKE ?';
            push @query_params, "%$description%";
        }

        if ($notes) {
            push @conditions,   'notes ILIKE ?';
            push @query_params, "%$notes%";
        }

        if ($reference) {
            push @conditions,   'reference ILIKE ?';
            push @query_params, "%$reference%";
        }

        if (@conditions) {
            $query .= ' WHERE ' . join( ' AND ', @conditions );
        }

        $query .= " ORDER BY transdate $sort";
        $query .= " LIMIT ? OFFSET ?";
        push @query_params, $limit, $offset;

# If accno is specified, collect transaction IDs that involve the specified account number
        my %transaction_ids_for_accno;
        if ($accno) {
            my $accno_query =
'SELECT DISTINCT acc_trans.trans_id FROM acc_trans JOIN chart ON acc_trans.chart_id = chart.id WHERE chart.accno = ?';
            my $accno_results = $dbs->query( $accno_query, $accno );
            while ( my $row = $accno_results->hash ) {
                $transaction_ids_for_accno{ $row->{trans_id} } = 1;
            }
        }

        my $ngl_results = $dbs->query( $query, @query_params );
        my @transactions;

        while ( my $transaction = $ngl_results->hash ) {

      # If accno is specified and the transaction ID is not in the list, skip it
            next
              if ( $accno
                && !$transaction_ids_for_accno{ $transaction->{id} } );

            my $entries_results = $dbs->query(
'SELECT chart.accno, chart.description, acc_trans.amount, acc_trans.source, acc_trans.memo, acc_trans.tax_chart_id, acc_trans.taxamount, acc_trans.fx_transaction, acc_trans.cleared FROM acc_trans JOIN chart ON acc_trans.chart_id = chart.id WHERE acc_trans.trans_id = ?',
                $transaction->{id}
            );
            my @lines;

            while ( my $line = $entries_results->hash ) {
                my $debit         = $line->{amount} < 0  ? -$line->{amount} : 0;
                my $credit        = $line->{amount} >= 0 ? $line->{amount}  : 0;
                my $fxTransaction = $line->{fx_transaction} == 1 ? \1 : \0;
                my $taxAccount =
                  $line->{tax_chart_id} == 0 ? undef : $line->{tax_chart_id};

                push @lines,
                  {
                    accno         => $line->{accno},
                    debit         => $debit,
                    credit        => $credit,
                    memo          => $line->{memo},
                    source        => $line->{source},
                    taxAccount    => $taxAccount,
                    taxAmount     => $line->{taxamount},
                    fxTransaction => $fxTransaction,
                    cleared       => $line->{cleared},
                  };
            }

            $transaction->{lines} = \@lines;
            push @transactions, $transaction;
        }

        $c->render( json => \@transactions );
    }
);

#Get An Individual GL transaction
$api->get(
    '/:client/gl/transactions/:id' => sub {
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

                $new_line{accno} = $line->{accno};
                $new_line{taxAccount} =
                  $line->{tax_chart_id} == 0
                  ? undef
                  : $line->{tax_chart_id};   # Set to undef if tax_chart_id is 0
                $new_line{taxAmount} = $line->{taxamount};
                $new_line{cleared}   = $line->{cleared};
                $new_line{memo}      = $line->{memo};
                $new_line{source}    = $line->{source};

                # Modify fxTransaction assignment based on fx_transaction value
                $new_line{fxTransaction} =
                  $line->{fx_transaction} == 1 ? \1 : \0;

                $line = \%new_line;
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
    }
);

$api->post(
    '/:client/gl/transactions/:id' => { id => undef } => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $id;
        $id = $c->param('id');
        return unless $c->client_check($client);
        my $data = $c->req->json;

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Check for existing id in the GL table if id is provided
        if ($id) {
            my $existing_entry =
              $dbs->query( "SELECT id FROM gl WHERE id = ?", $id )->hash;
            unless ($existing_entry) {
                return $c->render(
                    status => 404,
                    json   => {
                        Error => {
                            message => "Transaction with ID $id not found."
                        }
                    }
                );
            }
        }

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

        # Check if 'lines' is present and is an array reference
        unless ( exists $data->{lines} && ref $data->{lines} eq 'ARRAY' ) {
            return $c->render(
                status => 400,
                json   => {
                    Error => {
                        message => "The 'lines' array is required.",
                    },
                },
            );
        }

        # Find the default currency from the database
        my $default_result = $dbs->query("SELECT curr FROM curr WHERE rn = 1");
        my $default_row    = $default_result->hash;
        unless ($default_row) {
            die "Default currency not found in the database!";
        }
        my $default_currency = $default_row->{curr};

# Check if the provided currency exists in the 'curr' column of the database table
        my $result = $dbs->query( "SELECT rn, curr FROM curr WHERE curr = ?",
            $data->{curr} );
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

 # If the provided currency is not the default currency, check for exchange rate
        my $row = $result->hash;
        if ( $row->{curr} ne $default_currency
            && !exists $data->{exchangeRate} )
        {
            return $c->render(
                status => 400,
                json   => {
                    Error => {
                        message =>
"A non-default currency has been used. Exchange rate is required.",
                    },
                },
            );
        }

        # Create a new form
        my $form = new Form;

        if ($id) {
            $form->{id} = $id;
        }

        if ( !$data->{department} ) { $data->{department} = 0 }

        # Load the input data into the form
        $form->{reference}       = $data->{reference};
        $form->{department}      = $data->{department};
        $form->{notes}           = $data->{notes};
        $form->{description}     = $data->{description};
        $form->{curr}            = $data->{curr};
        $form->{currency}        = $data->{curr};
        $form->{exchangerate}    = $data->{exchangeRate};
        $form->{transdate}       = $transdate;
        $form->{defaultcurrency} = $default_currency;

        my $total_debit  = 0;
        my $total_credit = 0;
        my $i            = 1;
        foreach my $line ( @{ $data->{lines} } ) {

# Subtract taxAmount from debit or credit if taxAccount and taxAmount are defined
            if ( defined $line->{taxAccount} && defined $line->{taxAmount} ) {

                $total_debit  += $line->{debit};
                $total_credit += $line->{credit};

                $line->{debit} -=
                  ( $line->{debit} > 0 ? $line->{taxAmount} : 0 );
                $line->{credit} -=
                  ( $line->{credit} > 0 ? $line->{taxAmount} : 0 );

                # Add new tax line to $form
                if ( $line->{debit} > 0 ) {
                    $form->{"debit_$i"}  = $line->{taxAmount};
                    $form->{"credit_$i"} = 0;
                }
                else {
                    $form->{"debit_$i"}  = 0;
                    $form->{"credit_$i"} = $line->{taxAmount};
                }

                $form->{"accno_$i"}  = $line->{taxAccount};
                $form->{"tax_$i"}    = 'auto';
                $form->{"memo_$i"}   = $line->{memo};
                $form->{"source_$i"} = $line->{source};

                $i++;    # Increment the counter after processing the tax line
            }

            # Process the regular line
            $form->{"debit_$i"}     = $line->{debit};
            $form->{"credit_$i"}    = $line->{credit};
            $form->{"accno_$i"}     = $line->{accno};
            $form->{"tax_$i"}       = $line->{taxAccount};
            $form->{"taxamount_$i"} = $line->{taxAmount};
            $form->{"cleared_$i"}   = $line->{cleared};
            $form->{"memo_$i"}      = $line->{memo};
            $form->{"source_$i"}    = $line->{source};

            $i++;    # Increment the counter after processing the regular line
        }

        # Check if total_debit equals total_credit
        unless ( $total_debit == $total_credit ) {
            return $c->render(
                status => 400,
                json   => {
                    Error => {
                        message =>
"Total Debits ($total_debit) must equal Total Credits ($total_credit).",
                    },
                },
            );
        }

        # Adjust row count based on the counter
        $form->{rowcount} = $i - 1;

        # Call the function to add the transaction
        $id = GL->post_transaction( $c->slconfig, $form );

        warn $c->dumper($form);

        my $ts =
          $dbs->query( "SELECT ts from gl WHERE id = ?", $form->{id} )
          ->hash->{ts};

        # Convert the Form object back into a JSON-like structure
        my $response_json = {
            id           => $form->{id},
            reference    => $form->{reference},
            department   => $form->{department},
            notes        => $form->{notes},
            description  => $form->{description},
            curr         => $form->{curr},
            exchangeRate => $form->{exchangerate},
            transdate    => $form->{transdate},
            employeeId   => $form->{employee_id},
            ts           => $ts,
            lines        => []
        };

        for my $i ( 1 .. $form->{rowcount} ) {

            my $taxAccount =
              $form->{"tax_$i"} == 0
              ? undef
              : $form->{"tax_$i"};    # Set to undef if the tax value is 0

            push @{ $response_json->{lines} },
              {
                debit         => $form->{"debit_$i"},
                credit        => $form->{"credit_$i"},
                accno         => $form->{"accno_$i"},
                taxAccount    => $taxAccount,
                taxAmount     => $form->{"taxamount_$i"},
                cleared       => $form->{"cleared_$i"},
                memo          => $form->{"memo_$i"},
                source        => $form->{"source_$i"},
                fxTransaction => \0,
              };
        }

        # If the transaction currency isn't the default currency
        if ( $form->{curr} ne $form->{defaultcurrency} ) {

            # Query the acc_trans table for the relevant entries
            my $fx_trans_entries = $dbs->query(
"SELECT amount, chart_id, tax_chart_id, taxamount, cleared, memo, source FROM acc_trans WHERE trans_id = ? AND fx_transaction = true",
                $form->{id}
            );

            while ( my $entry = $fx_trans_entries->hash ) {

                my $taxAccount =
                  $form->{"tax_$i"} == 0
                  ? undef
                  : $form->{"tax_$i"};    # Set to undef if the tax value is 0

                push @{ $response_json->{lines} },
                  {
                    debit  => $entry->{amount} > 0 ? $entry->{amount}  : 0,
                    credit => $entry->{amount} < 0 ? -$entry->{amount} : 0,
                    accno         => $entry->{chart_id},
                    taxAccount    => $taxAccount,
                    taxAmount     => $entry->{taxamount},
                    cleared       => $entry->{cleared},
                    memo          => $entry->{memo},
                    source        => $entry->{source},
                    fxTransaction => \1,
                  };
            }
        }

        my $status_code = $id ? 200 : 201;    # 200 for update, 201 for create

        $c->render(
            status => $status_code,
            json   => $response_json,
        );
    }
);

$api->delete(
    '/:client/gl/transactions/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $id     = $c->param('id');

        return unless $c->client_check($client);

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Check for existing id in the GL table
        my $existing_entry =
          $dbs->query( "SELECT id FROM gl WHERE id = ?", $id )->hash;
        unless ($existing_entry) {
            return $c->render(
                status => 404,
                json   => {
                    Error => {
                        message => "Transaction with ID $id not found."
                    }
                }
            );
        }

        # Create a new form and add the id
        my $form = new Form;
        $form->{id} = $id;

        # Delete the transaction
        GL->delete_transaction( $c->slconfig, $form );

        # Delete the entry from the gl table
        $dbs->query( "DELETE FROM gl WHERE id = ?", $id );

        $c->render(
            status => 200,
            json   => {
                message => "Successfully deleted the transaction with ID $id."
            }
        );
    }
);

app->start;
