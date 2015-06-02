#!/usr/bin/perl
# by Dmytro Vasyk aka Dimonous
# dimonous<at>dimonous<dot>biz<dot>ua
# Special For http://osokonline.com/
# 2015

# Модуль для платёжной системы easypay (easysoft.com.ua)
#   для биллинговой системы Nodeny 50/49
#
#   версия без цифровой подписи

use DBI;
use CGI;
use XML::Simple;
use Encode;
use Crypt::OpenSSL::RSA;
use MIME::Base64;

$main_config = '/usr/local/nodeny/nodeny.cfg.pl';
$call_pl = '/usr/local/nodeny/web/calls.pl';
$log_file='/usr/local/nodeny/easypay.log';
$log_file_main='/usr/local/nodeny/nodeny.log';

#$sign_enable=0; #  разрешить работать с цифровой подписью

$category_payment = '404'; # Категория "сообщения системы"
$category_confirm = '91';  # Категория "платежи EasyPay"

#  Ошибки (StatusCode), которые модуль может выдавать в систему
$Status_ok = 0;
$Status_wrong_command = 1;
$Status_wrong_account_id = 3;
$Status_wrong_account_csum = 4;
$Status_account_not_found = 5;
$Status_main_config_not_found = 6;
$Status_call_pl_not_found = 7;
$Status_no_db_connect = 8;
$Status_amount_not_correct = 9;
$Status_empty_order_id = 10;
$Status_empty_payment_id = 11;
$Status_invoice_not_confirmable = 12;

#  Состояние счета в таблице платежей
$Payment_state_new = 0;  #  новый, можна оплатить
$Payment_state_confirmed = 1;  #  счет оплачен
$payment_state_canceled = 2;  #  счет отменен

sub Curr_time
{
    my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=CORE::localtime(time);
    return sprintf "%04d-%02d-%02dT%02d:%02d:%02d",$year+1900,$mon+1,$mday,$hour,$min,$sec;
}

sub Decode_account
{
#  Функция перевода персонального платёжного кода в user id в базе данных
  my $account = $_[0];
  my $sum1 = $account % 10;
  my $mid = int($account / 10);
  my $sum2=0;
  $sum2+=$_ foreach split //, $mid;
  $sum2%=10;
  &Response($Status_wrong_account_csum, 'Неверный персональный платёжный код: ' . $account) if $sum1!=$sum2;
  return $mid;
}


sub Log
{
  my ($time);
  my $message = "Easypay: " . encode('cp1251',decode('utf8',$_[0]));
  open LOG, ">>$log_file";
  $time = CORE::localtime;
  print LOG "$time: $message\n";
  close LOG;
  open LOG_MAIN, ">>$log_file_main";
  print LOG_MAIN "$time: $message\n";
  close LOG_MAIN;
}

sub Response
{
#  Вывод ответа в формате XML
  my $status_code = $_[0];
  my $log_message = $_[1];
  print "Content-type: text/xml\n\n";
  print "<Response>\n";
  print "<StatusCode>$status_code</StatusCode>\n";
  print "<StatusDetail>$log_message</StatusDetail>\n";
  print "<DateTime>$current_time</DateTime>\n";
  print "<Sign></Sign>\n";
  if (defined($_[2])) {
    $dop_info = $_[2];
    if ($dop_info eq 'check') {
      print "<AccountInfo>\n";
      print "<FIO>$_[3]</FIO>\n";
      print "<Balance>$_[4]</Balance>\n";
      print "<Tarif>$_[5]</Tarif>\n";
      print "</AccountInfo>\n";
    } elsif ($dop_info eq 'payment') {
      print "<PaymentId>$_[3]</PaymentId>\n";
    } elsif ($dop_info eq 'confirm') {
      print "<OrderDate>$_[3]</OrderDate>\n";
      system("/usr/local/nodeny/web/send.py success $mid $sum $txn_id EasyPay");
    } elsif ($dop_info eq 'cancel') {
      print "<CancelDate>$_[3]</CancelDate>\n";
    }
  }
  print "</Response>\n";
  &Log($log_message);
  exit;
}

sub Connect_db
{
  &Response($Status_main_config_not_found, 'Ошибка модуля биллинга: main config not found') unless -e $main_config;
  require $main_config;
  &Response($Status_call_pl_not_found, 'Ошибка модуля биллинга: call.pl not found') unless -e $call_pl;
  require $call_pl;
  my $dbh=DBI->connect("DBI:mysql:database=$db_name;host=$db_server;mysql_connect_timeout=$mysql_connect_timeout;", $user,$pw,{PrintError=>1});
  &Response($Status_no_db_connect, 'Ошибка модуля биллинга: no database connect') unless $dbh;
  $dbh->do('SET NAMES UTF8');
  return $dbh;
}


my $request = CGI::Vars();
my $xml_body = $request->{'POSTDATA'};
my $parser = XMLin($request->{'POSTDATA'});

$current_time = &Curr_time();

if (defined($parser->{'Check'})) {
#
#  Обработка запроса CHECK (получение информации о пользователе)
#
  my $account = $parser->{'Check'}->{'Account'};
  my $service_id = $parser->{'Check'}->{'ServiceId'};
  &Response($Status_wrong_account_id, 'Неверный формат персонального платёжного кода') unless ($account=~/^\d+\d$/);
  $account = &Decode_account($account);
  my $dbh = Connect_db();
  $p = &sql_select_line($dbh, "SELECT
    u.fio as fio,
    u.balance as balance,
    p.price as abonplata,
    u.srvs as srvs
    FROM users u, plans2 p
    WHERE u.paket=p.id AND u.id='$account' AND u.mid='0'");
  &Response($Status_account_not_found, 'Пользователь не найден в базе данных: ID:' . $account) unless $p;
  my $srvs_sum = 0;
  my $sr = $p->{srvs};
  if (!($p->{srvs} & 0x80000000)) {
    for ($i=1;$i<32;$i++,$sr>>=1) {
      next unless $srv_n[$i];
      next if !($sr & 1);
      $srvs_sum+=$srv_p[$i];
    }
  }
  my $balance_at_end = $p->{balance} - $p->{abonplata} - $srvs_sum;
  &Response($Status_ok, 'Пользователь существует: ID:' . $account . ' ФИО:&lt;' . $p->{fio} . '&gt; Баланс на конец месяца:' . $balance_at_end , 'check', $p->{fio}, $balance_at_end, $p->{abonplata} + $srvs_sum);
} elsif (defined($parser->{'Payment'})) {
#
#  Обработка запроса PAYMENT (выписываение счета на оплату)
#
  my $account = $parser->{'Payment'}->{'Account'};
  my $service_id = $parser->{'Payment'}->{'ServiceId'};
  my $amount = $parser->{'Payment'}->{'Amount'};
  my $order_id = $parser->{'Payment'}->{'OrderId'};
  &Response($Status_wrong_account_id, 'Неверный формат персонального платёжного кода') unless ($account=~/^\d+\d$/);
  &Response($Status_amount_not_correct, 'Некорректная сумма платежа') unless $amount>0;
  &Response($Status_empty_order_id, 'Отсутствует номер заказа') unless $order_id;
  $account = &Decode_account($account);
  my $dbh = Connect_db();
  $p = &sql_select_line($dbh, "SELECT
    u.fio as fio,
    u.balance as balance,
    p.price as abonplata,
    u.srvs as srvs
    FROM users u, plans2 p
    WHERE u.paket=p.id AND u.id='$account' AND u.mid='0'");
  &Response($Status_account_not_found, 'Пользователь не найден в базе данных: ID:' . $account) unless $p;
  my $payment_time = $parser->{'DateTime'};
  my $comment=decode('utf8','Выписан счёт на оплату в системе easypay');
  my $reason="$payment_time;$order_id;$amount;$Payment_state_new";
  $dbh->do("INSERT INTO pays SET
    mid='$account',
    cash=0,
    time=UNIX_TIMESTAMP('$current_time'),
    admin_id=0,
    admin_ip=0,
    office=0,
    bonus='y',
    reason='$reason',
    coment='$comment',
    type=50,
    category=$category_payment
  ");
  my $payment_id = $dbh->{mysql_insertid};
  &Response($Status_payment_not_stored, 'Невозможно выписать счёт') unless $payment_id;
  &Response($Status_ok, 'Выписан счет на оплату в платёжной системе Easypay: ID:' . $account . ' ФИО:&lt;' . $p->{fio} . '&gt; summa:' . $amount . ' счёт:' . $payment_id, 'payment', $payment_id);
} elsif (defined($parser->{'Confirm'})) {
#
#  Обработка запроса COMFIRM (событие успешной оплаты счёта)
#
  my $service_id = $parser->{'Confirm'}->{'ServiceId'};
  my $payment_id = $parser->{'Confirm'}->{'PaymentId'};
  &Response($Status_empty_payment_id, 'Отсутствует номер платежа') unless $payment_id;
  my $dbh = Connect_db();
  $p = &sql_select_line($dbh, "SELECT
    mid as account, reason FROM pays
    WHERE id=$payment_id");
  &Response($Status_invoice_not_found, 'Счет  не найден в базе данных: payment_id:' . $payment_id) unless $p;
  my $account = $p->{account};
  my $reason = $p->{reason};
  my ($payment_time,$order_id,$amount,$payment_state) = split(';',$reason);
  &Response($Status_invoice_not_confirmable, 'Счет уже оплачен или отменен: payment_id:' . $payment_id) unless $payment_state==$Payment_state_new;
  $p = &sql_select_line($dbh, "SELECT
    u.balance as balance
    FROM users u
    WHERE u.id='$account' AND u.mid='0'");
  &Response($Status_account_not_found, 'Пользователь не найден в базе данных: ID:' . $account) unless $p;
  my $new_balance += $p->{balance} + $amount;
  my $reason=decode('utf8','Получены деньги через оплату счёта в системе easypay. OrderID:'.$order_id);
  $dbh->do("INSERT INTO pays SET
    mid='$account',
    cash='$amount',
    time=UNIX_TIMESTAMP('$current_time'),
    admin_id=0,
    admin_ip=0,
    office=0,
    bonus='y',
    reason='$reason',
    type=10,
    category=$category_confirm
  ");
  $dbh->do("UPDATE users SET balance='$new_balance' WHERE id='$account'");
  $reason="$payment_time;$order_id;$amount;$Payment_state_confirmed";
  $dbh->do("UPDATE pays SET reason='$reason' WHERE id='$payment_id'");
  $dbh->do("UPDATE users SET state='on' WHERE state!='on' AND balance >= limit_balance AND (id=$account OR mid=$account)");
  &Response($Status_ok, 'Оплачен счёт на оплату easypay. OrderID:'.$order_id, 'confirm', $current_time);
} elsif (defined($parser->{'Cancel'})) {
#
#  Обработка запроса CANCEL (событие отмены оплаты счёта)
#
  my $service_id = $parser->{'Cancel'}->{'ServiceId'};
  my $payment_id = $parser->{'Cancel'}->{'PaymentId'};
  &Response($Status_empty_payment_id, 'Отсутствует номер платежа') unless $payment_id;
  my $dbh = Connect_db();
  $p = &sql_select_line($dbh, "SELECT
    mid as account, reason FROM pays
    WHERE id=$payment_id");
  &Response($Status_invoice_not_found, 'Счет  не найден в базе данных: payment_id:' . $payment_id) unless $p;
  my $account = $p->{account};
  my $reason = $p->{reason};
  my ($payment_time,$order_id,$amount,$payment_state) = split(';',$reason);
  &Response($Status_invoice_not_confirmable, 'Счет уже оплачен или отменен: payment_id:' . $payment_id) unless $payment_state==$Payment_state_new;
  $p = &sql_select_line($dbh, "SELECT
    u.balance as balance
    FROM users u
    WHERE u.id='$account' AND u.mid='0'");
  &Response($Status_account_not_found, 'Пользователь не найден в базе данных: ID:' . $account) unless $p;
  my $reason=decode('utf8','Счет на оплату в системе easypay отменён. OrderID:'.$order_id);
  $dbh->do("INSERT INTO pays SET
    mid='$account',
    cash=0,
    time=UNIX_TIMESTAMP('$current_time'),
    admin_id=0,
    admin_ip=0,
    office=0,
    bonus='y',
    reason='$reason',
    type=50,
    category=$category_payment
  ");
  $reason="$payment_time;$order_id;$amount;$Payment_state_canceled";
  $dbh->do("UPDATE pays SET reason='$reason' WHERE id='$payment_id'");
  &Response($Status_ok, 'Счёт на оплату easypay отменен. OrderID:'.$order_id, 'cancel', $current_time);
} else {
  print "Content-type: text/xml\n\n";
  print "<Response>\n";
  print "<StatusCode>1</StatusCode>\n";
  print "<StatusDetail>Команда в запросе не поддедживается текущей версией модуля</StatusDetail>\n";
  print "<DateTime>$current_time</DateTime>\n";
  print "<Sign></Sign>\n";
  print "</Response>\n";
  exit;
}

