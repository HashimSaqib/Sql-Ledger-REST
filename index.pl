#!/usr/bin/env perl

BEGIN {
    push @INC, '.';
}

use Mojolicious::Lite;
use XML::Hash::XS;
use Data::Dumper;
use Mojo::Util qw(unquote);
use Mojo::JSON qw(decode_json);
use DBI;
use DBIx::Simple;
use XML::Simple;
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



#########################
####                 #### 
#### GL Transactions #### 
####                 ####
#########################


$api->get('/:client/gl/transactions/lines' => sub {
    my $c      = shift;
    my $params = $c->req->params->to_hash;
    my $client = $c->param('client');

    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

    my $form = new Form;
    for ( keys %$params ) { $form->{$_} = $params->{$_} if $params->{$_} }
    $form->{category} = 'X';

    GL->transactions( $c->slconfig, $form );

    # Check if the result is undefined, empty, or has no entries
    if (  !defined($form->{GL})
        || ref($form->{GL}) ne 'ARRAY'
        || scalar(@{ $form->{GL} }) == 0 )
    {
        return $c->render(
            status => 404,
            json   => { error => 
            { message => "No transactions found" },
            }
        );
    }

    # Assuming $form->{GL} is an array reference with hash references
    foreach my $transaction ( @{ $form->{GL} } ) {
        delete $transaction->{$_}
          for
          qw(address address1 address2 city country entry_id name name_id zipcode);
    }

    $c->render( status => 200, json => $form->{GL} );
});

$api->get(
    '/:client/gl/transactions' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        return unless $c->client_check($client);

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Searching Parameters
        my $datefrom   = $c->param('datefrom');
        my $dateto     = $c->param('dateto');
        my $description = $c->param('description');
        my $notes       = $c->param('notes');
        my $reference   = $c->param('reference');
        my $accno       = $c->param('accno');

        # Validate Date
        if ($datefrom) { $c->validate_date($datefrom) or return; }
        if ($dateto)   { $c->validate_date($dateto)   or return; }

        my $query =
'SELECT id, reference, transdate, description, notes, curr, department_id AS department, approved, ts, exchangerate AS exchangeRate, employee_id FROM gl';
        my @query_params;

        my @conditions;
        if ( $datefrom && $dateto ) {
            push @conditions, 'transdate BETWEEN ? AND ?';
            push @query_params, $datefrom, $dateto;
        }
        elsif ($datefrom) {
            push @conditions,   'transdate = ?';
            push @query_params, $datefrom;
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
                my $fx_transaction = $line->{fx_transaction} == 1 ? \1 : \0;
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
                    fx_transaction => $fx_transaction,
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

                # Modify fx_transaction assignment based on fx_transaction value
                $new_line{fx_transaction} =
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
    '/:client/gl/transactions' => sub {
        my $c = shift;
        $c->app->log->error("Check");
        my $client = $c->param('client');
        return unless $c->client_check($client);
        my $data = $c->req->json;

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        api_gl_transaction( $c, $dbs, $data );
    }
);

$api->put(
    '/:client/gl/transactions/:id' => sub {
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
                        error => {
                            message => "Transaction with ID $id not found."
                        }
                    }
                );
            }
        }
        api_gl_transaction( $c, $dbs, $data, $id );
    }
);

sub api_gl_transaction () {
    my ( $c, $dbs, $data, $id ) = @_;

    # Check if 'transdate' is present in the data
    unless ( exists $data->{transdate} ) {
        return $c->render(
            status => 400,
            json   => {
                error => {
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
                error => {
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
    my $result =
      $dbs->query( "SELECT rn, curr FROM curr WHERE curr = ?", $data->{curr} );
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

        my $acc_id =
          $dbs->query( "SELECT id from chart WHERE accno = ?", $line->{accno} );

        if ( !$acc_id ) {
            return $c->render(
                status => 400,
                json   => {
                    Error => {
                            message => "Account with the accno "
                          . $line->{accno}
                          . " does not exist.",
                    },
                },
            );
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
      $dbs->query( "SELECT ts from gl WHERE id = ?", $form->{id} )->hash->{ts};

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
            fx_transaction => \0,
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
                debit         => $entry->{amount} > 0 ? $entry->{amount}  : 0,
                credit        => $entry->{amount} < 0 ? -$entry->{amount} : 0,
                accno         => $entry->{chart_id},
                taxAccount    => $taxAccount,
                taxAmount     => $entry->{taxamount},
                cleared       => $entry->{cleared},
                memo          => $entry->{memo},
                source        => $entry->{source},
                fx_transaction => \1,
              };
        }
    }

    my $status_code =
      $c->param('id') ? 200 : 201;    # 200 for update, 201 for create

    $c->render(
        status => $status_code,
        json   => $response_json,
    );
}

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

        $c->render( status => 204, data => '' );
    }
);

#########################
####                 #### 
####      Chart      #### 
####                 ####
#########################

$api->get('/:client/charts' => sub {
    my $c      = shift;
    my $client = $c->param('client');

    return unless $c->client_check($client);

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
    my $dbs = $c->dbs($client);

    # Get link strings from query parameters (e.g., ?link=AR_tax,AP_tax)
    my @links = $c->param('link') ? split(',', $c->param('link')) : ();

    # Start with the base query
    my $sql = "SELECT * FROM chart";

    # If links are provided, add a WHERE clause to filter entries
    if (@links) {
        my @conditions;
        foreach my $link (@links) {
        }
        my $where_clause = join(' AND ', @conditions);
        $sql .= " WHERE $where_clause";
    }

    # Execute the query with the necessary parameters
    my $entries = $dbs->query($sql, map { "%$_%" } @links)->hashes;

    if ($entries) {
        return $c->render(
            status => 200,
            json   => $entries
        );
    } else {
        return $c->render(
            status => 404,
            json   => { error => { message => "No accounts found" } }
        );
    }
});



$api->post('/:client/charts' => sub {
    my $c      = shift;
    my $client = $c->param('client');

    return unless $c->client_check($client);

    # Create the DBIx::Simple handle
    $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
    my $dbs = $c->dbs($client);

    # Parse JSON request body
    my $data = $c->req->json;

    unless ($data) {
        return $c->render(
            status => 400,
            json   => { error => { message => "Invalid JSON in request body" } }
        );
    }

    # Get the necessary parameters from the parsed JSON
    my $accno       = $data->{accno};
    my $description = $data->{description};
    my $charttype   = $data->{charttype} // 'A';
    my $category    = $data->{category};
    my $link        = $data->{link};
    my $gifi_accno  = $data->{gifi_accno};
    my $contra      = $data->{contra} // 'false';
    my $allow_gl    = $data->{allow_gl};

    # Validate required fields
    unless ($accno && $description) {
        return $c->render(
            status => 400,
            json   => { error => { message => "Missing required fields: accno, description" } }
        );
    }

    # Validate charttype
    unless ($charttype eq 'A' || $charttype eq 'H') {
        return $c->render(
            status => 400,
            json   => { error => { message => "Invalid charttype. Must be either 'A' or 'H'" } }
        );
    }

    # Validate category
    my @valid_categories = qw(A L I Q E);
    unless ($category && length($category) == 1 && grep { $_ eq $category } @valid_categories) {
        return $c->render(
            status => 400,
            json   => { error => { message => "Invalid category. Must be one of 'A', 'L', 'I', 'Q', 'E'" } }
        );
    }

    # Prepare SQL for insertion
    my $sql_insert = "INSERT INTO chart (accno, description, charttype, category, link, gifi_accno, contra, allow_gl) 
                      VALUES (?, ?, ?, ?, ?, ?, ?, ?)";

    # Execute the insertion
    my $result = $dbs->query($sql_insert, $accno, $description, $charttype, $category, $link, $gifi_accno, $contra, $allow_gl);

    if ($result->affected) {
        # Retrieve the newly created entry
        my $new_entry = $dbs->query("SELECT * FROM chart WHERE accno = ?", $accno)->hash;

        return $c->render(
            status => 201,
            json   => { message => "Chart entry created successfully", entry => $new_entry }
        );
    } else {
        return $c->render(
            status => 500,
            json   => { error => { message => "Failed to create chart entry" } }
        );
    }
});


app->start;
