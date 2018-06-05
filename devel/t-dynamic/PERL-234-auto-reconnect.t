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
use Test::More 0.88;
use Test::Fatal;

use lib "t/lib";
use lib "devel/lib";

use if $ENV{MONGOVERBOSE}, qw/Log::Any::Adapter Stderr/;

use MongoDBTest::Orchestrator;

my $orc = MongoDBTest::Orchestrator->new( config_file => "devel/config/mongod-2.6.yml" );
$orc->start;
$ENV{MONGOD} = $orc->as_uri;

use MongoDBTest qw/build_client get_test_db clear_testdbs/;

my $server = $orc->deployment->get_server("host1");
my $orig_port = $server->port;

ok ($server->is_alive, "Server is alive");

my $c = build_client();
my $coll = get_test_db($c)->get_collection("testc");
inserted_ok($coll, $coll->insert_one({pre => 'stop'})->inserted_id);

$server->stop();

ok (! $server->is_alive, "Server is dead");

$server->start($orig_port);

ok ($server->is_alive, "Server is alive");

my $res;
like(
    exception { $res = $coll->insert_one({post => 'reconnect'}) },
    qr/NetworkError/,
    "first attempt to contact server fails",
);

note "waiting for connection cooldown to expire";
sleep 6; # must outwait the cooldown time

is(
    exception { $res = $coll->insert_one({post => 'reconnect'}) },
    undef,
    "second attempt to contact server succeeds",
);


inserted_ok($coll, $res->inserted_id );

clear_testdbs;

done_testing;

sub inserted_ok {
    my ($coll, $id) = @_;

    if ( $id ) {
        ok($coll->find_id($id), "$id inserted (find)");
    }
    else {
        fail "no document inserted to find";
    }
}
