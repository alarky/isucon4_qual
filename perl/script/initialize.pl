use strict;
use warnings;
use utf8;
use DBIx::Sunny;
use Redis;

sub d { use Data::Dumper; print Dumper(@_); }

my $host = $ENV{ISU4_DB_HOST} || '127.0.0.1';
my $port = $ENV{ISU4_DB_PORT} || 3306;
my $username = $ENV{ISU4_DB_USER} || 'root';
my $password = $ENV{ISU4_DB_PASSWORD};
my $database = $ENV{ISU4_DB_NAME} || 'isu4_qualifier';
my $dbh = DBIx::Sunny->connect(
        "dbi:mysql:database=$database;host=$host;port=$port", $username, $password, {
            RaiseError => 1,
            PrintError => 0,
            AutoInactiveDestroy => 1,
            mysql_enable_utf8   => 1,
            mysql_auto_reconnect => 1,
        },
    );

my $redis = Redis->new;
$redis->flushall;

my $logs = $dbh->select_all("SELECT * FROM login_log");
my %failure_by_user;
my %failure_by_ip;
my %last_succeeded;
for my $log (@$logs) {
    $failure_by_user{$log->{user_id}}++;
    $failure_by_ip{$log->{ip}}++;

    if ($log->{succeeded}) {
        $last_succeeded{$log->{user_id}} = $log->{created_at};
    }
}

d \%failure_by_user;
my $wait=<STDIN>;
d \%failure_by_ip;
my $wait=<STDIN>;
d \%last_succeeded;
