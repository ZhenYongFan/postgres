# Test logical replication behavior with heap rewrites
use strict;
use warnings;
use PostgresNode;
use TestLib;
use Test::More tests => 3;

sub wait_for_caught_up
{
	my ($node, $appname) = @_;

	$node->poll_query_until('postgres',
"SELECT pg_current_wal_lsn() <= replay_lsn FROM pg_stat_replication WHERE application_name = '$appname';"
	) or die "Timed out while waiting for subscriber to catch up";
}

my $node_publisher = get_new_node('publisher');
$node_publisher->init(allows_streaming => 'logical');
$node_publisher->start;

my $node_subscriber = get_new_node('subscriber');
$node_subscriber->init(allows_streaming => 'logical');
$node_subscriber->start;

my $ddl = "CREATE TABLE test1 (a int, b text);";
$node_publisher->safe_psql('postgres', $ddl);
$node_subscriber->safe_psql('postgres', $ddl);

$ddl = "CREATE TABLE test2 (a int, b text);";
$node_publisher->safe_psql('postgres', $ddl);
$node_subscriber->safe_psql('postgres', $ddl);

$node_publisher->safe_psql('postgres', q{INSERT INTO test2 (a, b) VALUES (10, 'ten'), (20, 'twenty');});
$node_publisher->safe_psql('postgres', 'CREATE MATERIALIZED VIEW test3 AS SELECT a, b FROM test2;');

my $publisher_connstr = $node_publisher->connstr . ' dbname=postgres';
my $appname           = 'encoding_test';

$node_publisher->safe_psql('postgres',
	"CREATE PUBLICATION mypub FOR ALL TABLES;");
$node_subscriber->safe_psql('postgres',
"CREATE SUBSCRIPTION mysub CONNECTION '$publisher_connstr application_name=$appname' PUBLICATION mypub;"
);

wait_for_caught_up($node_publisher, $appname);

# Wait for initial sync to finish as well
my $synced_query =
    "SELECT count(1) = 0 FROM pg_subscription_rel WHERE srsubstate NOT IN ('s', 'r');";
$node_subscriber->poll_query_until('postgres', $synced_query)
  or die "Timed out while waiting for subscriber to synchronize data";

$node_publisher->safe_psql('postgres', q{INSERT INTO test1 (a, b) VALUES (1, 'one'), (2, 'two');});

wait_for_caught_up($node_publisher, $appname);

is($node_subscriber->safe_psql('postgres', q{SELECT a, b FROM test1}),
   qq(1|one
2|two),
   'initial data replicated to subscriber');

# DDL that causes a heap rewrite
my $ddl2 = "ALTER TABLE test1 ADD c int NOT NULL DEFAULT 0;";
$node_subscriber->safe_psql('postgres', $ddl2);
$node_publisher->safe_psql('postgres', $ddl2);

wait_for_caught_up($node_publisher, $appname);

$node_publisher->safe_psql('postgres', q{INSERT INTO test1 (a, b, c) VALUES (3, 'three', 33);});

wait_for_caught_up($node_publisher, $appname);

is($node_subscriber->safe_psql('postgres', q{SELECT a, b, c FROM test1}),
   qq(1|one|0
2|two|0
3|three|33),
   'data replicated to subscriber');

# Another DDL that causes a heap rewrite
$node_publisher->safe_psql('postgres', 'REFRESH MATERIALIZED VIEW test3;');

# an additional row to check if the REFRESH worked
$node_publisher->safe_psql('postgres', q{INSERT INTO test2 (a, b) VALUES (30, 'thirty');});

wait_for_caught_up($node_publisher, $appname);

is($node_subscriber->safe_psql('postgres', q{SELECT COUNT(1) FROM test2}), 3,
   'data replicated to subscriber after refresh');

$node_subscriber->stop;
$node_publisher->stop;
