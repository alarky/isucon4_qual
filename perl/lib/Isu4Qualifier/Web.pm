package Isu4Qualifier::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Digest::SHA qw/ sha256_hex /;
use Data::Dumper;
use Redis;
use Encode;
use JSON::XS;
use JSON qw/ decode_json /;
use POSIX qw/strftime/;

my $redis      = Redis->new(sock => '/tmp/redis.sock');

my $dbh = DBIx::Sunny->connect( 'dbi:mysql:database=isu4_qualifier;host=127.0.0.1;port=3306',
                                'root',
                                '',
                                {
                                    RaiseError => 1,
                                    PrintError => 0,
                                    AutoInactiveDestroy => 1,
                                    mysql_enable_utf8 => 1,
                                    mysql_auto_reconnect => 1,
                                }
                            );

my $users = $dbh->select_all('SELECT * FROM users');
my %LOGIN_OF;
my %ID_OF;
for (@$users) {
    $LOGIN_OF{$_->{login}} = $_;
    $ID_OF{$_->{id}} = $_;
}

sub config {
  my ($self) = @_;
  $self->{_config} ||= {
    user_lock_threshold => $ENV{'ISU4_USER_LOCK_THRESHOLD'} || 3,
    ip_ban_threshold => $ENV{'ISU4_IP_BAN_THRESHOLD'} || 10
  };
};

sub db {
  my ($self) = @_;
  my $host = $ENV{ISU4_DB_HOST} || '127.0.0.1';
  my $port = $ENV{ISU4_DB_PORT} || 3306;
  my $username = $ENV{ISU4_DB_USER} || 'root';
  my $password = $ENV{ISU4_DB_PASSWORD};
  my $database = $ENV{ISU4_DB_NAME} || 'isu4_qualifier';

  $self->{_db} ||= do {
    DBIx::Sunny->connect(
      "dbi:mysql:database=$database;host=$host;port=$port", $username, $password, {
        RaiseError => 1,
        PrintError => 0,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8   => 1,
        mysql_auto_reconnect => 1,
      },
    );
  };
}

sub user_locked {
  my ($self, $user) = @_;

  my $fail_count = $redis->hget('failure_by_user', $user->{'id'});
  if(!$fail_count){
     return undef;
  }

  return $self->config->{user_lock_threshold} <= $fail_count;
};

sub ip_banned {
  my ($self, $ip) = @_;

  my $fail_count = $redis->hget('failure_by_ip', $ip);
  if(!$fail_count){
     return undef;
  }

  return $self->config->{ip_ban_threshold} <= $fail_count;
};

sub attempt_login {
  my ($self, $login, $password, $ip) = @_;
  my $user = $LOGIN_OF{$login};

  if ($self->ip_banned($ip)) {
    $self->login_log(0, $login, $ip, $user ? $user->{id} : undef);
    return undef, 'banned';
  }

  if ($self->user_locked($user)) {
    $self->login_log(0, $login, $ip, $user->{id});
    return undef, 'locked';
  }

  if ($user && sha256_hex($password.':'.$user->{salt}) eq $user->{password_hash}) {
    $self->login_log(1, $login, $ip, $user->{id});
    return $user, undef;
  }
  elsif ($user) {
    $self->login_log(0, $login, $ip, $user->{id});
    return undef, 'wrong_password';
  }
  else {
    $self->login_log(0, $login, $ip);
    return undef, 'wrong_login';
  }
};

sub current_user {
  my ($self, $user_id) = @_;

  return $ID_OF{$user_id};
};

sub last_login {
  my ($self, $user_id) = @_;


  my $succeeded = $redis->hget('last_succeeded', $user_id);
  $succeeded = decode_json($succeeded);

  my $user = +{
   login => $ID_OF{$user_id}->{login},
   ip	=> $succeeded->{ip},
   created_at => $succeeded->{created_at},
  };

  $user;
};

sub banned_ips {
  my ($self) = @_;
  my @ips;
  my $threshold = $self->config->{ip_ban_threshold};

  my $not_succeeded = $self->db->select_all('SELECT ip FROM (SELECT ip, MAX(succeeded) as max_succeeded, COUNT(1) as cnt FROM login_log GROUP BY ip) AS t0 WHERE t0.max_succeeded = 0 AND t0.cnt >= ?', $threshold);

  foreach my $row (@$not_succeeded) {
    push @ips, $row->{ip};
  }

  my $last_succeeds = $self->db->select_all('SELECT ip, MAX(id) AS last_login_id FROM login_log WHERE succeeded = 1 GROUP by ip');

  foreach my $row (@$last_succeeds) {
    my $count = $self->db->select_one('SELECT COUNT(1) AS cnt FROM login_log WHERE ip = ? AND ? < id', $row->{ip}, $row->{last_login_id});
    if ($threshold <= $count) {
      push @ips, $row->{ip};
    }
  }

  \@ips;
};

sub locked_users {
  my ($self) = @_;
  my @user_ids;
  my $threshold = $self->config->{user_lock_threshold};

  my $not_succeeded = $self->db->select_all('SELECT user_id, login FROM (SELECT user_id, login, MAX(succeeded) as max_succeeded, COUNT(1) as cnt FROM login_log GROUP BY user_id) AS t0 WHERE t0.user_id IS NOT NULL AND t0.max_succeeded = 0 AND t0.cnt >= ?', $threshold);

  foreach my $row (@$not_succeeded) {
    push @user_ids, $row->{login};
  }

  my $last_succeeds = $self->db->select_all('SELECT user_id, login, MAX(id) AS last_login_id FROM login_log WHERE user_id IS NOT NULL AND succeeded = 1 GROUP BY user_id');

  foreach my $row (@$last_succeeds) {
    my $count = $self->db->select_one('SELECT COUNT(1) AS cnt FROM login_log WHERE user_id = ? AND ? < id', $row->{user_id}, $row->{last_login_id});
    if ($threshold <= $count) {
      push @user_ids, $row->{login};
    }
  }

  \@user_ids;
};

sub login_log {
  my ($self, $succeeded, $login, $ip, $user_id) = @_;
  if($succeeded == 1){
     my $old_ip = "";
     my $old_created_at = "";
     my $last_succeeded = $redis->hget('last_succeeded', $user_id);
     if($last_succeeded)
     {
         $last_succeeded = decode_json($last_succeeded);
         $old_ip	 = $last_succeeded->{next_ip};
         $old_created_at = $last_succeeded->{next_created_at};
     }
     my $succeeded_info = +{
         created_at => $old_created_at,
         ip => $old_ip,
         next_created_at => strftime("%Y-%m-%d %H:%M:%S",localtime),
         next_ip => $ip
     };
     my $json_succeeded = encode_json($succeeded_info);

     $redis->hset('last_succeeded', $user_id, $json_succeeded);
     $redis->hset('failure_by_user', $user_id, 0);
     $redis->hset('failure_by_ip', $ip, 0);
  }
  else
  {
     # TODO: data存在するかのチェックいるのか
     my $increment = 1;
     $redis->hincrby('failure_by_user', $user_id, $increment);
     $redis->hincrby('failure_by_ip', $ip, $increment);

     $redis->hincrby('total_failure_by_user', $user_id, $increment);
  }
};

sub set_flash {
  my ($self, $c, $msg) = @_;
  $c->req->env->{'psgix.session'}->{flash} = $msg;
};

sub pop_flash {
  my ($self, $c, $msg) = @_;
  my $flash = $c->req->env->{'psgix.session'}->{flash};
  delete $c->req->env->{'psgix.session'}->{flash};
  $flash;
};

filter 'session' => sub {
  my ($app) = @_;
  sub {
    my ($self, $c) = @_;
    my $sid = $c->req->env->{'psgix.session.options'}->{id};
    $c->stash->{session_id} = $sid;
    $c->stash->{session}    = $c->req->env->{'psgix.session'};
    $app->($self, $c);
  };
};

get '/' => [qw(session)] => sub {
  my ($self, $c) = @_;

  $c->render('index.tx', { flash => $self->pop_flash($c) });
};

post '/login' => sub {
  my ($self, $c) = @_;
  my $msg;

  my ($user, $err) = $self->attempt_login(
    $c->req->param('login'),
    $c->req->param('password'),
    $c->req->address
  );

  if ($user && $user->{id}) {
    $c->req->env->{'psgix.session'}->{user_id} = $user->{id};
    $c->redirect('/mypage');
  }
  else {
    if ($err eq 'locked') {
      $self->set_flash($c, 'This account is locked.');
    }
    elsif ($err eq 'banned') {
      $self->set_flash($c, 'You\'re banned.');
    }
    else {
      $self->set_flash($c, 'Wrong username or password');
    }
    $c->redirect('/');
  }
};

get '/mypage' => [qw(session)] => sub {
  my ($self, $c) = @_;
  my $user_id = $c->req->env->{'psgix.session'}->{user_id};
  my $user = $self->current_user($user_id);
  my $msg;

  if ($user) {
    $c->render('mypage.tx', { last_login => $self->last_login($user_id) });
  }
  else {
    $self->set_flash($c, 'You must be logged in');
    $c->redirect('/');
  }
};

get '/report' => sub {
  my ($self, $c) = @_;
  $c->render_json({
    banned_ips => $self->banned_ips,
    locked_users => $self->locked_users,
  });
};

1;
