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
use SQL::Abstract;
use XML::Simple;
use SL::Form;
use SL::AM;
use SL::CT;
use SL::RP;
use SL::AA;
use SL::IS;
use SL::IR;
use SL::CA;
use SL::GL;
use DateTime::Format::ISO8601;

my %myconfig = (
    dateformat   => 'yyyy/mm/dd',
    dbdriver     => 'Pg',
    dbhost       => '',
    dbname       => 'neoledger',
    dbpasswd     => '',
    dbport       => '',
    dbuser       => 'postgres',
    numberformat => '1,000.00',
);

helper slconfig => sub { \%myconfig };

helper dbs => sub {
    my ( $c, $dbname ) = @_;

    my $dbh;
    eval {
        $dbh = DBI->connect( "dbi:Pg:dbname=$dbname", 'postgres', '',
            { RaiseError => 1, PrintError => 0 } );
    };

    if ( $@ || !$dbh ) {
        my $error_message = $DBI::errstr // $@ // "Unknown error";

        # Ensure no further processing or responses are sent after this
        $c->render(
            status => 500,
            json   => {
                message =>
                  "Failed to connect to the database '$dbname': $error_message"
            }
        );
        $c->app->log->error(
            "Failed to connect to the database '$dbname': $error_message");
        return undef;    # Return undef to prevent further processing
    }

    my $dbs = DBIx::Simple->connect($dbh);
    return $dbs;
};

helper validate_date => sub {
    my ( $c, $date ) = @_;
    unless ( $date =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        return $c->render(
            status => 400,
            json   => {
                message =>
"Invalid date format. Expected ISO 8601 date format (YYYY-MM-DD).",
            },
        );
    }
    return 1;    # return true if the date is valid
};

#Ledger API Calls

my $r = app->routes;

my $api = $r->under('/api/client/:client');

# Enable CORS for all routes
app->hook(
    before_dispatch => sub {
        my $c = shift;
        $c->res->headers->header( 'Access-Control-Allow-Origin' => '*' );
        $c->res->headers->header( 'Access-Control-Allow-Methods' =>
              'GET, POST, PUT, DELETE, OPTIONS' );
        $c->res->headers->header( 'Access-Control-Allow-Headers' =>
              'Origin, X-Requested-With, Content-Type, Accept, Authorization' );
        $c->res->headers->header( 'Access-Control-Max-Age' => '3600' );
        $c->res->headers->header(
            'Access-Control-Allow-Credentials' => 'true' );
        return unless $c->req->method eq 'OPTIONS';
        $c->render( text => '', status => 204 );
        return 1;
    }
);

# Override render_exception to return JSON and include CORS headers
app->hook(
    around_dispatch => sub {
        my ( $next, $c ) = @_;
        eval { $next->(); 1 } or do {
            my $error = $@ || 'Unknown error';
            $c->res->headers->header( 'Access-Control-Allow-Origin' => '*' );
            $c->res->headers->header( 'Access-Control-Allow-Methods' =>
                  'GET, POST, PUT, DELETE, OPTIONS' );
            $c->res->headers->header( 'Access-Control-Allow-Headers' =>
'Origin, X-Requested-With, Content-Type, Accept, Authorization'
            );
            $c->render(
                status => 500,
                json   => { message => "$error" }
            );
        };
    }
);

#########################
#### AUTH   +        ####
#### ACCESS CONTROL  ####
####                 ####
#########################

my $allMenuItems =
qq'AR--AR;AR--Add Transaction;AR--Sales Invoice;AR--Credit Note;AR--Credit Invoice;AR--Reports;POS--POS;POS--Sale;POS--Open;POS--Receipts;Customers--Customers;Customers--Add Customer;Customers--Reports;AP--AP;AP--Add Transaction;AP--Vendor Invoice;AP--Debit Note;AP--Debit Invoice;AP--Reports;Vendors--Vendors;Vendors--Add Vendor;Vendors--Reports;Cash--Cash;Cash--Receipt;Cash--Receipts;Cash--Payment;Cash--Payments;Cash--Void Check;Cash--Reissue Check;Cash--Void Receipt;Cash--Reissue Receipt;Cash--FX Adjustment;Cash--Reconciliation;Cash--Reports;Vouchers--Vouchers;Vouchers--Payable;Vouchers--Payment;Vouchers--Payments;Vouchers--Payment Reversal;Vouchers--General Ledger;Vouchers--Reports;HR--HR;HR--Employees;HR--Payroll;Order Entry--Order Entry;Order Entry--Sales Order;Order Entry--Purchase Order;Order Entry--Reports;Order Entry--Generate;Order Entry--Consolidate;Logistics--Logistics;Logistics--Merchandise;Logistics--Reports;Quotations--Quotations;Quotations--Quotation;Quotations--RFQ;Quotations--Reports;General Ledger--General Ledger;General Ledger--Add Transaction;General Ledger--Reports;Goods & Services--Goods & Services;Goods & Services--Add Part;Goods & Services--Add Service;Goods & Services--Add Kit;Goods & Services--Add Assembly;Goods & Services--Add Labor/Overhead;Goods & Services--Add Group;Goods & Services--Add Pricegroup;Goods & Services--Stock Assembly;Goods & Services--Stock Adjustment;Goods & Services--Reports;Goods & Services--Changeup;Goods & Services--Translations;Projects & Jobs--Projects & Jobs;Projects & Jobs--Projects;Projects & Jobs--Jobs;Projects & Jobs--Translations;Reference Documents--Reference Documents;Reference Documents--Add Document;Reference Documents--List Documents;Image Files--Image Files;Image Files--Add File;Image Files--List Files;Reports--Reports;Reports--Chart of Accounts;Reports--Trial Balance;Reports--Income Statement;Reports--Balance Sheet;Recurring Transactions--Recurring Transactions;Batch--Batch;Batch--Print;Batch--Email;Batch--Queue;Exchange Rates--Exchange Rates;Import--Import;Import--Customers;Import--Vendors;Import--Parts;Import--Services;Import--Labor/Overhead;Import--Sales Invoices;Import--Groups;Import--Payments;Import--Sales Orders;Import--Purchase Orders;Import--Chart of Accounts;Import--General Ledger;Export--Export;Export--Payments;System--System;System--Defaults;System--Audit Control;System--Audit Log;System--Bank Accounts;System--Taxes;System--Currencies;System--Payment Methods;System--Workstations;System--Roles;System--Warehouses;System--Departments;System--Type of Business;System--Language;System--Mimetypes;System--SIC;System--Yearend;System--Maintenance;System--Backup;System--Chart of Accounts;System--html Templates;System--XML Templates;System--LaTeX Templates;System--Text Templates;Stylesheet--Stylesheet;Preferences--Preferences;New Window--New Window;Version--Version;Logout--Logout';
my $neoLedgerMenu =
qq'General Ledger--General Ledger;General Ledger--Add Transaction;General Ledger--Reports;System--System;System--Currencies';

helper check_perms => sub {
    my ( $c, $sessionkey, $permission ) = @_;

    my $session =
      $c->db->query( 'SELECT employeeid FROM apisessions WHERE sessionkey = ?',
        $sessionkey )->hash;

    unless ($session) {
        return $c->render(
            status => 403,
            json   => { message => "Invalid session key" }
        );
    }

    my $employee_id = $session->{employeeid};

    # Step 2: Check if the user is an admin
    my $is_admin =
      $c->db->query( 'SELECT admin FROM apilogin WHERE employeeid = ?',
        $employee_id )->hash->{admin};

    return 1 if $is_admin;

    # Step 3: Get the acsrole_id from the employee table
    my $acsrole_id =
      $c->db->query( 'SELECT acsrole_id FROM employee WHERE id = ?',
        $employee_id )->hash->{acsrole_id};

    # Step 4: Get the restricted permissions string from the acsrole table
    my $acs_string =
      $c->db->query( 'SELECT acs FROM acsrole WHERE id = ?', $acsrole_id )
      ->hash->{acs};

    # Step 5: Check if the permission string is in the restricted list
    my @restricted_perms = split( ';', $acs_string );
    foreach my $restricted_perm (@restricted_perms) {
        if ( $permission eq $restricted_perm ) {
            return $c->render(
                status => 403,
                json => { message => "Permission '$permission' is not allowed" }
            );
        }
    }

    # If the permission is not in the restricted list, return true
    return 1;
};

$api->post(
    '/auth/validate' => sub {
        my $c          = shift;
        my $client     = $c->param('client');
        my $sessionkey = $c->req->params->to_hash->{sessionkey};
        my $dbs        = $c->dbs($client);

        # Query the database to validate the sessionkey
        my $result =
          $dbs->query( "SELECT * FROM apisession WHERE sessionkey = ?",
            $sessionkey )->hash;
        warn($result);
        if ($result) {

            # Session key is valid, return true
            $c->render( json => { success => 1 } );
        }
        else {
# Session key is not valid, return a 401 Not Authorized code with an error message
            $c->render(
                status => 401,
                json   => { message => "Not Authorized: Invalid session key" }
            );
        }
    }
);

$api->post(
    '/auth/login' => sub {
        my $c      = shift;
        my $params = $c->req->json;
        my $client = $c->param('client');

        my $username_with_db = $params->{username};
        my $password         = $params->{password};

        # Split the username based on "@"
        my ( $username, $dbname ) = split( '@', $username_with_db );

        # Check if dbname is provided
        unless ($dbname) {
            return $c->render(
                status => 400,
                json   =>
                  { message => "Database name is required in the username" }
            );
        }

        # Establish a database connection using the dbname
        my $dbs = $c->dbs($dbname);

# If the database connection failed, it would have already returned an error response
        return unless $dbs;

        # Check for the username in the employee table
        my $employee =
          $dbs->query( 'SELECT id FROM employee WHERE login = ?', $username )
          ->hash;
        unless ($employee) {
            return $c->render(
                status => 400,
                json   => { message => "Employee record does not exist" }
            );
        }

        my $employee_id = $employee->{id};

 # Check if the API account exists in the apilogin table and verify the password
        my $login = $dbs->query( '
        SELECT password
        FROM apilogin
        WHERE employeeid = ? AND crypt(?, password) = password
    ', $employee_id, $password )->hash;

        unless ($login) {
            return $c->render(
                status => 400,
                json   => { message => "Incorrect username or password" }
            );
        }

        my $session_key = $dbs->query(
'INSERT INTO apisession (employeeid, sessionkey) VALUES (?, encode(gen_random_bytes(32), ?)) RETURNING sessionkey',
            $employee_id, 'hex'
        )->hash->{sessionkey};

        # Return the session key
        return $c->render(
            json => { sessionkey => $session_key, client => $dbname } );
    }
);

$api->post(
    '/auth/create_api_login' => sub {
        my $c          = shift;
        my $client     = $c->param('client');
        my $params     = $c->req->params->to_hash;
        my $employeeid = $params->{employeeid};
        my $password   = $params->{password};

        # Step 1: Check for missing parameters
        unless ( $employeeid && $password ) {
            return $c->render(
                status => 400,
                json   => {
                    message =>
                      "Missing required parameters 'employeeid' or 'password'"
                }
            );
        }

        # Step 2: Try to connect to the existing database using the client name
        my $dbs;
        eval { $dbs = $c->dbs($client); };
        if ($@) {
            return $c->render(
                status => 500,
                json   => {
                    message =>
                      "Failed to connect to the client database '$client': $@"
                }
            );
        }

        # Step 3: Use PostgreSQL to hash the password with bcrypt
        my $hashed_password;
        eval {
            my $query = '
            INSERT INTO apilogin (employeeid, password)
            VALUES (?, crypt(?, gen_salt(\'bf\')))
        ';
            $dbs->query( $query, $employeeid, $password );
        };
        if ($@) {
            return $c->render(
                status => 500,
                json   => { message => "Failed to create API login: $@" }
            );
        }

        # Step 4: Return success message
        return $c->render(
            json => {
                message =>
                  "API login created successfully for user '$employeeid'"
            }
        );
    }
);

#########################
####                 ####
#### GL Transactions ####
####                 ####
#########################

$api->get(
    '/gl/transactions/lines' => sub {
        my $c      = shift;
        my $params = $c->req->params->to_hash;
        my $client = $c->param('client');

        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;
        for ( keys %$params ) { $form->{$_} = $params->{$_} if $params->{$_} }
        $form->{category} = 'X';

        GL->transactions( $c->slconfig, $form );

        # Check if the result is undefined, empty, or has no entries
        if (  !defined( $form->{GL} )
            || ref( $form->{GL} ) ne 'ARRAY'
            || scalar( @{ $form->{GL} } ) == 0 )
        {
            return $c->render(
                status => 404,
                json   => { message => "No transactions found" },
            );
        }

        # Assuming $form->{GL} is an array reference with hash references
        foreach my $transaction ( @{ $form->{GL} } ) {
            my $full_address = join( ' ',
                $form->{address1} // '',
                $form->{address2} // '',
                $form->{city}     // '',
                $form->{state}    // '',
                $form->{country}  // '' );

        }

        $c->render( status => 200, json => $form->{GL} );
    }
);

$api->get(
    '/gl/transactions' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Searching Parameters
        my $datefrom    = $c->param('datefrom');
        my $dateto      = $c->param('dateto');
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
                my $debit  = $line->{amount} < 0  ? -$line->{amount}   : 0;
                my $credit = $line->{amount} >= 0 ? $line->{amount}    : 0;
                my $fx_transaction = $line->{fx_transaction} == 1 ? \1 : \0;
                my $taxAccount =
                  $line->{tax_chart_id} == 0 ? undef : $line->{tax_chart_id};

                push @lines,
                  {
                    accno          => $line->{accno},
                    debit          => $debit,
                    credit         => $credit,
                    memo           => $line->{memo},
                    source         => $line->{source},
                    taxAccount     => $taxAccount,
                    taxAmount      => $line->{taxamount},
                    fx_transaction => $fx_transaction,
                    cleared        => $line->{cleared},
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
    '/gl/transactions/:id' => sub {
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
                    message => "The requested GL transaction was not found."
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
    '/gl/transactions' => sub {
        my $c = shift;
        $c->app->log->error("Check");
        my $client = $c->param('client');
        my $data   = $c->req->json;

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        api_gl_transaction( $c, $dbs, $data );
    }
);

$api->put(
    '/gl/transactions/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $id;
        $id = $c->param('id');
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
                        message => "Transaction with ID $id not found."
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
            json   => { message => "The 'transdate' field is required.", }
        );
    }

    my $transdate = $data->{transdate};

    # Validate 'transdate' format (ISO date format)
    unless ( $transdate =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        return $c->render(
            status => 400,
            json   => {
                message =>
"Invalid 'transdate' format. Expected ISO 8601 date format (YYYY-MM-DD)."
            }

        );
    }

    # Check if 'lines' is present and is an array reference
    unless ( exists $data->{lines} && ref $data->{lines} eq 'ARRAY' ) {
        return $c->render(
            status => 400,
            json   => { message => "The 'lines' array is required." },
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
            json   => { message => "The specified currency does not exist." },
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
                message =>
"A non-default currency has been used. Exchange rate is required."
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
                        message => "Account with the accno "
                      . $line->{accno}
                      . " does not exist.",
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
                message =>
"Total Debits ($total_debit) must equal Total Credits ($total_credit).",
            },
        );
    }

    # Adjust row count based on the counter
    $form->{rowcount} = $i - 1;

    # Call the function to add the transaction
    $id = GL->post_transaction( $c->slconfig, $form );

    warn $c->dumper($form);

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
        lines        => []
    };

    for my $i ( 1 .. $form->{rowcount} ) {

        my $taxAccount =
          $form->{"tax_$i"} == 0
          ? undef
          : $form->{"tax_$i"};    # Set to undef if the tax value is 0

        push @{ $response_json->{lines} },
          {
            debit          => $form->{"debit_$i"},
            credit         => $form->{"credit_$i"},
            accno          => $form->{"accno_$i"},
            taxAccount     => $taxAccount,
            taxAmount      => $form->{"taxamount_$i"},
            cleared        => $form->{"cleared_$i"},
            memo           => $form->{"memo_$i"},
            source         => $form->{"source_$i"},
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
                debit          => $entry->{amount} > 0 ? $entry->{amount}  : 0,
                credit         => $entry->{amount} < 0 ? -$entry->{amount} : 0,
                accno          => $entry->{chart_id},
                taxAccount     => $taxAccount,
                taxAmount      => $entry->{taxamount},
                cleared        => $entry->{cleared},
                memo           => $entry->{memo},
                source         => $entry->{source},
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
    '/gl/transactions/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $id     = $c->param('id');

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
                    message => "Transaction with ID $id not found."
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

$api->get(
    '/charts' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Get link strings from query parameters (e.g., ?link=AR_tax,AP_tax)
        my @links = $c->param('link') ? split( ',', $c->param('link') ) : ();

        # Start with the base query
        my $sql = "SELECT * FROM chart";

        # If links are provided, add a WHERE clause to filter entries
        if (@links) {
            my @conditions;
            foreach my $link (@links) {
            }
            my $where_clause = join( ' AND ', @conditions );
            $sql .= " WHERE $where_clause";
        }

        # Execute the query with the necessary parameters
        my $entries = $dbs->query( $sql, map { "%$_%" } @links )->hashes;

        # Add the "label" property to each entry
        foreach my $entry (@$entries) {
            $entry->{label} = $entry->{accno} . '--' . $entry->{description};
        }

        if ($entries) {
            return $c->render(
                status => 200,
                json   => $entries
            );
        }
        else {
            return $c->render(
                status => 404,
                json   => { message => "No accounts found" }
            );
        }
    }
);

$api->post(
    '/charts' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        # Create the DBIx::Simple handle
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $dbs = $c->dbs($client);

        # Parse JSON request body
        my $data = $c->req->json;

        unless ($data) {
            return $c->render(
                status => 400,
                json   => { message => "Invalid JSON in request body" }
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
        unless ( $accno && $description ) {
            return $c->render(
                status => 400,
                json   =>
                  { message => "Missing required fields: accno, description" }
            );
        }

        # Validate charttype
        unless ( $charttype eq 'A' || $charttype eq 'H' ) {
            return $c->render(
                status => 400,
                json   =>
                  { message => "Invalid charttype. Must be either 'A' or 'H'" }
            );
        }

        # Validate category
        my @valid_categories = qw(A L I Q E);
        unless ( $category && length($category) == 1 && grep { $_ eq $category }
            @valid_categories )
        {
            return $c->render(
                status => 400,
                json   => {
                    message =>
                      "Invalid category. Must be one of 'A', 'L', 'I', 'Q', 'E'"
                }
            );
        }

        # Prepare SQL for insertion
        my $sql_insert =
"INSERT INTO chart (accno, description, charttype, category, link, gifi_accno, contra, allow_gl) 
                      VALUES (?, ?, ?, ?, ?, ?, ?, ?)";

        # Execute the insertion
        my $result = $dbs->query(
            $sql_insert, $accno,      $description, $charttype, $category,
            $link,       $gifi_accno, $contra,      $allow_gl
        );

        if ( $result->affected ) {

            # Retrieve the newly created entry
            my $new_entry =
              $dbs->query( "SELECT * FROM chart WHERE accno = ?", $accno )
              ->hash;

            return $c->render(
                status => 201,
                json   => {
                    message => "Chart entry created successfully",
                    entry   => $new_entry
                }
            );
        }
        else {
            return $c->render(
                status => 500,
                json   => { message => "Failed to create chart entry" }
            );
        }
    }
);

###############################
####                       ####
####    System Settings    ####
####                       ####
###############################

$api->get(
    '/system/currencies' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        my $dbs = $c->dbs($client);

        my $currencies;
        eval { $currencies = $dbs->query("SELECT * FROM curr")->hashes; };

        if ($@) {
            return $c->render(
                status => 500,
                json   =>
                  { error => { message => 'Failed to retrieve currencies' } }
            );
        }

        $c->render( json => $currencies );
    }
);

$api->any(
    [qw(POST PUT)] => '/system/currencies' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        # Get JSON body params
        my $params = $c->req->json;
        my $curr   = $params->{curr} || '';
        my $prec   = $params->{prec} || '';

        # Validate input parameters
        unless ( $curr =~ /^[A-Z]{3}$/
            && $prec =~ /^\d+$/
            && $prec >= 0
            && $prec <= 10 )
        {
            return $c->render(
                status => 400,
                json   => { message => 'Invalid input parameters' }
            );
        }

        my $dbs = $c->dbs($client);

        my $form = new Form;
        $form->{curr}             = $curr;
        $form->{prec}             = $prec;
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        AM->save_currency( $c->slconfig, $form );

        return $c->render(
            status => 201,
            json   => { message => 'Currency created successfully' }
        );
    }
);

$api->delete(
    '/system/currencies/:curr' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $curr   = $c->param('curr');

        # Validate input parameter
        unless ( $curr =~ /^[A-Z]{3}$/ ) {
            return $c->render(
                status => 400,
                json   => { message => 'Invalid currency code' }
            );
        }

        my $dbs = $c->dbs($client);

        # Create a form object with the currency code
        my $form = new Form;
        $form->{curr} = $curr;
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        # Call the delete method from AM module
        AM->delete_currency( $c->slconfig, $form );

        # Return no content (204)
        return $c->rendered(204);
    }
);

##########################
####                  ####
#### Goods & Services ####
####                  ####
##########################

$api->get(
    '/items' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $dbs    = $c->dbs($client);

        my $parts = $dbs->query("SELECT * FROM parts")->hashes;

 # For each part, fetch the related tax accounts with accno from the chart table
 # Need this to map with taxes array from customer/vendor
        foreach my $part (@$parts) {
            my $taxaccounts = $dbs->query( "
            SELECT chart.accno 
            FROM partstax 
            JOIN chart ON partstax.chart_id = chart.id 
            WHERE partstax.parts_id = ?",
                $part->{id} )->arrays;

            # Add tax accounts as an array of accnos
            $part->{taxaccounts} = [ map { $_->[0] } @$taxaccounts ];
        }

        # Render the response as JSON
        $c->render( json => { parts => $parts } );
    }
);

###############################
####                       ####
####         ARAP          ####
####                       ####
###############################

$api->get(
    '/arap/transactions/:type' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $type   = $c->param('type');
        my $data   = $c->req->json;

        # Validate the type parameter
        unless ( $type eq 'vendor' || $type eq 'customer' ) {
            return $c->render(
                json => {
                    error => 'Invalid type. Must be either vendor or customer.'
                },
                status => 400
            );
        }

        my $form = new Form;
        $form->{vc}               = $type;
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        $form->{summary}          = 1;
        AA->transactions( $c->slconfig, $form );

        my @transactions = @{ $form->{transactions} };

        $c->render( json => \@transactions );
    }
);

###############################
####                       ####
####           AR          ####
####                       ####
###############################

$api->post(
    '/ar/:type/:id' => { id => undef } => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $data   = $c->req->json;
        warn( Dumper($data) );
        my $type = $c->param('type');
        my $dbs  = $c->dbs($client);
        my $id   = $c->param('id');
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;

        $form->{type} = $type;

        # Basic invoice details
        $form->{id} = undef;
        if ($id) {
            $form->{id} = $id;
        }
        $form->{invnumber}    = $data->{invNumber}   || '';
        $form->{description}  = $data->{description} || '';
        $form->{transdate}    = $data->{invDate};
        $form->{duedate}      = $data->{dueDate};
        $form->{customer_id}  = $data->{selectedCustomer}->{id};
        $form->{customer}     = $data->{selectedCustomer}->{name};
        $form->{currency}     = $data->{selectedCurrency}->{curr};
        $form->{exchangerate} = $data->{selectedCurrency}->{rn} || 1;
        $form->{AR}           = $data->{salesAccount}->{accno};
        $form->{notes}        = $data->{notes}    || '';
        $form->{intnotes}     = $data->{intnotes} || '';

        # Other invoice details
        $form->{ordnumber}     = $data->{ordNumber}     || '';
        $form->{ponumber}      = $data->{poNumber}      || '';
        $form->{shippingpoint} = $data->{shippingPoint} || '';
        $form->{shipvia}       = $data->{shipVia}       || '';
        $form->{waybill}       = $data->{wayBill}       || '';

        # Line items
        $form->{rowcount} = scalar @{ $data->{lines} };
        for my $i ( 1 .. $form->{rowcount} ) {
            my $line = $data->{lines}[ $i - 1 ];
            $form->{"id_$i"}          = $line->{number};
            $form->{"description_$i"} = $line->{description};
            $form->{"qty_$i"}         = $line->{qty};
            $form->{"sellprice_$i"}   = $line->{price};
            $form->{"discount_$i"}    = $line->{discount} || 0;
            $form->{"unit_$i"}        = $line->{unit}     || '';
        }

        # Payments
        $form->{paidaccounts} = 0;    # Start with 0 processed payments
        for my $payment ( @{ $data->{payments} } ) {
            next unless $payment->{amount} > 0;
            $form->{paidaccounts}++;
            my $i = $form->{paidaccounts};
            $form->{"datepaid_$i"} = $payment->{date};
            $form->{"source_$i"}   = $payment->{source} || '';
            $form->{"paid_$i"}     = $payment->{amount};
            $form->{"AR_paid_$i"}  = $payment->{account};
        }

        $form->{taxincluded} = 0;

        # Taxes
        if ( $data->{taxes} && ref( $data->{taxes} ) eq 'ARRAY' ) {
            my @taxaccounts;
            for my $tax ( @{ $data->{taxes} } ) {
                push @taxaccounts, $tax->{accno};
                $form->{"$tax->{accno}_rate"} = $tax->{rate};
            }
            $form->{taxaccounts} = join( ' ', @taxaccounts );
            $form->{taxincluded} = $data->{taxincluded};
        }

        $form->{department_id} = undef;
        $form->{employee_id}   = undef;
        $form->{language_code} = 'en';
        $form->{precision}     = $data->{selectedCurrency}->{prec} || 2;

        warn( Dumper($form) );

        IS->post_invoice( $c->slconfig, $form );

        $c->render( json => { data => Dumper($form) } );
    }
);

$api->get(
    '/ar/salesinvoice/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $data   = $c->req->json;
        my $id     = $c->param('id');

        # Initialize required variables
        my $dbs = $c->dbs($client);
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $ml       = 1;
        my %myconfig = ();    # Configuration hash

        # Create a new Form object and set initial values
        my $form = Form->new;
        $form->{id}   = $id;
        $form->{vc}   = "customer";
        $form->{type} = 'invoice';

        # Retrieve the invoice details
        IS->retrieve_invoice( $c->slconfig, $form );
        IS->invoice_details( $c->slconfig, $form );

        # Create payments array
        my @payments;

     # Check if $form->{acc_trans}{AR_paid} is defined and is an array reference
        if ( defined $form->{acc_trans}{AR_paid}
            && ref( $form->{acc_trans}{AR_paid} ) eq 'ARRAY' )
        {
            for my $i ( 1 .. scalar @{ $form->{acc_trans}{AR_paid} } ) {
                push @payments,
                  {
                    date   => $form->{acc_trans}{AR_paid}[ $i - 1 ]{transdate},
                    source => $form->{acc_trans}{AR_paid}[ $i - 1 ]{source},
                    memo   => $form->{acc_trans}{AR_paid}[ $i - 1 ]{memo},
                    amount => $form->{acc_trans}{AR_paid}[ $i - 1 ]{amount} *
                      -1 * $ml,
                    account =>
"$form->{acc_trans}{AR_paid}[$i-1]{accno}--$form->{acc_trans}{AR_paid}[$i-1]{description}"
                  };
            }
        }

        my @lines = map {
            {
                id          => $_->{id},
                partnumber  => $_->{partnumber},
                description => $_->{description},
                qty         => $_->{qty},
                oh          => $_->{onhand},
                unit        => $_->{unit},
                price       => $_->{sellprice},
                discount    => $_->{discount},
                taxaccounts => [ split ' ', $_->{taxaccounts} ]
            }
        } @{ $form->{invoice_details} };

        # Process tax information
        my @taxes;
        if ( $form->{acc_trans}{AR_tax} ) {
            @taxes = map {
                {
                    accno  => $_->{accno},
                    amount => $_->{amount},
                    rate   => $_->{rate}
                }
            } @{ $form->{acc_trans}{AR_tax} };
        }

        # Create the transformed data structure
        my $json_data = {
            customernumber => $form->{customernumber},
            shippingPoint  => $form->{shippingpoint},
            shipVia        => $form->{shipvia},
            wayBill        => $form->{waybill},
            description    => $form->{invdescription},
            notes          => $form->{notes},
            intnotes       => $form->{intnotes},
            invNumber      => $form->{invnumber},
            ordNumber      => $form->{ordnumber},
            invDate        => $form->{transdate},
            dueDate        => $form->{duedate},
            poNumber       => $form->{ponumber},
            salesAccount   => $form->{acc_trans}{AR}[0],
            lines          => \@lines,
            payments       => \@payments
        };

        # Add tax information if present
        if (@taxes) {
            $json_data->{taxes}       = \@taxes;
            $json_data->{taxincluded} = $form->{taxincluded};
        }

        # Render the structured response in JSON format
        $c->render( json => $json_data );
    }
);

###############################
####                       ####
####       Customers       ####
####                       ####
###############################

$api->get(
    '/customers' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;

        $form->{vc} = 'customer';
        AA->all_names( $c->slconfig, $form );
        warn( Dumper($form) );

        for my $item ( @{ $form->{all_vc} } ) {
            $item->{label} = $item->{name} . " -- " . $item->{customernumber};
        }

        $c->render( json => { customers => $form->{all_vc} } );
    }
);

$api->get(
    '/customers/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;
        $form->{vc}          = 'customer';
        $form->{customer_id} = $c->param('id');

        AA->get_name( $c->slconfig, $form );

        # Construct the full address
        my $full_address = join( ' ',
            $form->{address1} // '',
            $form->{address2} // '',
            $form->{city}     // '',
            $form->{state}    // '',
            $form->{country}  // '' );

        # Add the full address to the form object
        $form->{full_address} = $full_address;

        # Dereference the form object to render it as JSON
        $c->render( json => {%$form} );
    }
);

###############################
####                       ####
####       Vendors         ####
####                       ####
###############################

$api->get(
    '/vendors' => sub {
        my $c      = shift;
        my $client = $c->param('client');

        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;

        $form->{vc} = 'vendor';
        AA->all_names( $c->slconfig, $form );
        warn( Dumper($form) );

        for my $item ( @{ $form->{all_vc} } ) {
            $item->{label} = $item->{name} . " -- " . $item->{vendornumber};
        }

        $c->render( json => { vendors => $form->{all_vc} } );
    }
);

$api->get(
    '/vendors/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;
        $form->{vc}        = 'vendor';
        $form->{vendor_id} = $c->param('id');

        AA->get_name( $c->slconfig, $form );

        # Construct the full address
        my $full_address = join( ' ',
            $form->{address1} // '',
            $form->{address2} // '',
            $form->{city}     // '',
            $form->{state}    // '',
            $form->{country}  // '' );

        # Add the full address to the form object
        $form->{full_address} = $full_address;

        # Dereference the form object to render it as JSON
        $c->render( json => {%$form} );
    }
);

###############################
####                       ####
####           AP          ####
####                       ####
###############################

$api->post(
    '/ap/:type/:id' => { id => undef } => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $data   = $c->req->json;
        warn( Dumper($data) );
        my $type = $c->param('type');
        my $dbs  = $c->dbs($client);
        my $id   = $c->param('id');
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";

        my $form = new Form;

        $form->{type} = $type;

        # Basic invoice details
        $form->{id} = undef;
        if ($id) {
            $form->{id} = $id;
        }
        $form->{invnumber}    = $data->{invNumber}   || '';
        $form->{description}  = $data->{description} || '';
        $form->{transdate}    = $data->{invDate};
        $form->{duedate}      = $data->{dueDate};
        $form->{vendor_id}    = $data->{selectedVendor}->{id};
        $form->{vendor}       = $data->{selectedVendor}->{name};
        $form->{currency}     = $data->{selectedCurrency}->{curr};
        $form->{exchangerate} = $data->{selectedCurrency}->{rn} || 1;
        $form->{AP}           = $data->{salesAccount}->{accno};
        $form->{notes}        = $data->{notes}    || '';
        $form->{intnotes}     = $data->{intnotes} || '';

        # Other invoice details
        $form->{ordnumber}     = $data->{ordNumber}     || '';
        $form->{ponumber}      = $data->{poNumber}      || '';
        $form->{shippingpoint} = $data->{shippingPoint} || '';
        $form->{shipvia}       = $data->{shipVia}       || '';
        $form->{waybill}       = $data->{wayBill}       || '';

        # Line items
        $form->{rowcount} = scalar @{ $data->{lines} };
        for my $i ( 1 .. $form->{rowcount} ) {
            my $line = $data->{lines}[ $i - 1 ];
            $form->{"id_$i"}          = $line->{number};
            $form->{"description_$i"} = $line->{description};
            $form->{"qty_$i"}         = $line->{qty};
            $form->{"sellprice_$i"}   = $line->{price};
            $form->{"discount_$i"}    = $line->{discount} || 0;
            $form->{"unit_$i"}        = $line->{unit}     || '';
        }

        # Payments
        $form->{paidaccounts} = 0;    # Start with 0 processed payments
        for my $payment ( @{ $data->{payments} } ) {
            next unless $payment->{amount} > 0;
            $form->{paidaccounts}++;
            my $i = $form->{paidaccounts};
            $form->{"datepaid_$i"} = $payment->{date};
            $form->{"source_$i"}   = $payment->{source} || '';
            $form->{"paid_$i"}     = $payment->{amount};
            $form->{"AP_paid_$i"}  = $payment->{account};
        }

        $form->{taxincluded} = 0;

        # Taxes
        if ( $data->{taxes} && ref( $data->{taxes} ) eq 'ARRAY' ) {
            my @taxaccounts;
            for my $tax ( @{ $data->{taxes} } ) {
                push @taxaccounts, $tax->{accno};
                $form->{"$tax->{accno}_rate"} = $tax->{rate};
            }
            $form->{taxaccounts} = join( ' ', @taxaccounts );
            $form->{taxincluded} = $data->{taxincluded};
        }

        $form->{department_id} = undef;
        $form->{employee_id}   = undef;
        $form->{language_code} = 'en';
        $form->{precision}     = $data->{selectedCurrency}->{prec} || 2;

        warn( Dumper($form) );

        IR->post_invoice( $c->slconfig, $form );

        $c->render( json => { data => Dumper($form) } );
    }
);

$api->get(
    '/ap/vendorinvoice/:id' => sub {
        my $c      = shift;
        my $client = $c->param('client');
        my $data   = $c->req->json;
        my $id     = $c->param('id');

        # Initialize required variables
        my $dbs = $c->dbs($client);
        $c->slconfig->{dbconnect} = "dbi:Pg:dbname=$client";
        my $ml       = 1;
        my %myconfig = ();    # Configuration hash

        # Create a new Form object and set initial values
        my $form = Form->new;
        $form->{id}   = $id;
        $form->{vc}   = "vendor";
        $form->{type} = 'invoice';

        # Retrieve the invoice details
        IR->retrieve_invoice( $c->slconfig, $form );
        IR->invoice_details( $c->slconfig, $form );

        # Create payments array
        my @payments;

     # Check if $form->{acc_trans}{AR_paid} is defined and is an array reference
        if ( defined $form->{acc_trans}{AP_paid}
            && ref( $form->{acc_trans}{AP_paid} ) eq 'ARRAY' )
        {
            for my $i ( 1 .. scalar @{ $form->{acc_trans}{AP_paid} } ) {
                push @payments,
                  {
                    date    => $form->{acc_trans}{AP_paid}[ $i - 1 ]{transdate},
                    source  => $form->{acc_trans}{AP_paid}[ $i - 1 ]{source},
                    memo    => $form->{acc_trans}{AP_paid}[ $i - 1 ]{memo},
                    amount  => $form->{acc_trans}{AP_paid}[ $i - 1 ]{amount},
                    account =>
"$form->{acc_trans}{AP_paid}[$i-1]{accno}--$form->{acc_trans}{AP_paid}[$i-1]{description}"
                  };
            }
        }

        my @lines = map {
            {
                id          => $_->{id},
                partnumber  => $_->{partnumber},
                description => $_->{description},
                qty         => $_->{qty},
                oh          => $_->{onhand},
                unit        => $_->{unit},
                price       => $_->{sellprice},
                discount    => $_->{discount},
                taxaccounts => [ split ' ', $_->{taxaccounts} ]
            }
        } @{ $form->{invoice_details} };

        # Process tax information
        my @taxes;
        if ( $form->{acc_trans}{AP_tax} ) {
            @taxes = map {
                {
                    accno  => $_->{accno},
                    amount => $_->{amount},
                    rate   => $_->{rate}
                }
            } @{ $form->{acc_trans}{AP_tax} };
        }

        # Create the transformed data structure
        my $json_data = {
            vendornumber  => $form->{vendornumber},
            shippingPoint => $form->{shippingpoint},
            shipVia       => $form->{shipvia},
            wayBill       => $form->{waybill},
            description   => $form->{invdescription},
            notes         => $form->{notes},
            intnotes      => $form->{intnotes},
            invNumber     => $form->{invnumber},
            ordNumber     => $form->{ordnumber},
            invDate       => $form->{transdate},
            dueDate       => $form->{duedate},
            poNumber      => $form->{ponumber},
            salesAccount  => $form->{acc_trans}{AP}[0],
            lines         => \@lines,
            payments      => \@payments
        };

        # Add tax information if present
        if (@taxes) {
            $json_data->{taxes}       = \@taxes;
            $json_data->{taxincluded} = $form->{taxincluded};
        }

        # Render the structured response in JSON format
        $c->render( json => $json_data );
    }
);
app->start;
