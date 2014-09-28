use strict;
use warnings;
use utf8;
use DBIx::Sunny;
use Redis;
use JSON::XS;

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
my %try_succeeced_by_user;
my %try_succeeced_by_ip;
my %try_succeeced_till_by_user;
my %try_succeeced_till_by_ip;
my %try_succeeced_try_by_user;
my %try_succeeced_try_by_ip;
my %total_failure_by_user;
my %total_failure_by_ip;
my %failure_by_user;
my %failure_by_ip;
my %last_succeeded;

for my $log (@$logs) {
    if ($log->{succeeded}) {
        $failure_by_user{$log->{user_id}} = 0;
        $failure_by_ip{$log->{ip}} = 0;
		$last_succeeded{$log->{user_id}} = encode_json(+{
			created_at => $log->{created_at},
			ip => $log->{ip},
		});
        $try_succeeced_till_by_user{$log->{user_id}}+=$try_succeeced_try_by_user{$log->{user_id}};
        $try_succeeced_till_by_ip{$log->{ip}}+=$try_succeeced_try_by_ip{$log->{ip}};
        $try_succeeced_try_by_user{$log->{user_id}} = 0;
        $try_succeeced_try_by_ip{$log->{ip}} = 0;
    } else {
        $try_succeeced_till_by_user{$log->{user_id}} = 0;
        $try_succeeced_till_by_ip{$log->{ip}} = 0;
        $total_failure_by_user{$log->{user_id}}++;
        $total_failure_by_ip{$log->{ip}}++;
        $failure_by_user{$log->{user_id}}++;
        $failure_by_ip{$log->{ip}}++;
    }
}
foreach my $user_key(%try_succeeced_till_by_user)
{
   $try_succeeced_by_user{$user_key} = encode_json(+{
       count_till_login => $try_succeeced_till_by_user{$user_key},
       count_trying => $try_succeeced_try_by_user{$user_key},
   });
}
foreach my $ip_key(%try_succeeced_till_by_ip)
{
   $try_succeeced_by_ip{$ip_key} = encode_json(+{
       count_till_login => $try_succeeced_till_by_ip{$ip_key},
       count_trying => $try_succeeced_try_by_ip{$ip_key},
   });
}

$redis->hmset('try_succeeced_by_user', %try_succeeced_by_user);
d $redis->hlen('try_succeeced_by_user');
$redis->hmset('try_succeeced_by_ip', %try_succeeced_by_ip);
d $redis->hlen('try_succeeced_by_ip');
$redis->hmset('total_failure_by_user', %total_failure_by_user);
d $redis->hlen('total_failure_by_user');
$redis->hmset('total_failure_by_ip', %total_failure_by_ip);
d $redis->hlen('total_failure_by_ip');
$redis->hmset('failure_by_user', %failure_by_user);
d $redis->hlen('failure_by_user');
$redis->hmset('failure_by_ip', %failure_by_ip);
d $redis->hlen('failure_by_ip');
$redis->hmset('last_succeeded', %last_succeeded);
d $redis->hlen('last_succeeded');
