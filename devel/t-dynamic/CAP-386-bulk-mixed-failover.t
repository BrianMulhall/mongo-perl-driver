#  Copyright 2014 - present MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

use strict;
use warnings;
use utf8;
use Test::More 0.88;
use Test::Fatal;
use Test::Deep qw/!blessed/;
use Scalar::Util qw/refaddr/;
use Tie::IxHash;
use boolean;

use MongoDB;
use MongoDB::Error;

use lib "t/lib";
use lib "devel/lib";

use if $ENV{MONGOVERBOSE}, qw/Log::Any::Adapter Stderr/;

use MongoDBTest::Orchestrator;

my $orc =
  MongoDBTest::Orchestrator->new(
    config_file => "devel/config/replicaset-mixed.yml" );
$orc->start;
$ENV{MONGOD} = $orc->as_uri;

use MongoDBTest qw/build_client get_test_db clear_testdbs/;


my $conn = build_client( dt_type => undef, server_selection_timeout_ms => 30000 );
my $admin  = $conn->get_database("admin");
my $testdb = get_test_db($conn);
my $coll   = $testdb->get_collection("test_collection");

note("QA-447 FAILOVER WITH MIXED VERSION");
subtest "mixed version stepdown" => sub {
    note "waiting for all hosts to be ready";
    $orc->deployment->server_set->wait_for_all_hosts;

    is( exception { $coll->drop }, undef, "drop collection" );

    # stopdown primary
    $orc->deployment->server_set->stepdown_primary(5);
    note "stepped down primary";

    $conn->topology_status( refresh => 1 );

    my $bulk = $coll->initialize_ordered_bulk_op;
    $bulk->insert_one( { _id => 1 } );

    my ( $result, $err );
    $err = exception { $result = $bulk->execute };
    is( $err, undef, "no error on insert" ) or diag explain $err;

    note "waiting for replica set stepdown to time out";
    sleep 6;

    # stepdown primary again to switch back
    $orc->deployment->server_set->stepdown_primary(5);
    note "stepped down primary again";

    $conn->topology_status( refresh => 1 );

    $bulk = $coll->initialize_ordered_bulk_op;
    $bulk->insert_one( { _id => 2 } );
    $err = exception { $result = $bulk->execute };
    is( $err, undef, "no error on insert" ) or diag explain $err;
};

clear_testdbs;

done_testing;
