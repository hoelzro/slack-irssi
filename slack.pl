#!/usr/bin/perl
#
# Copyright 2014 Ted 'tedski' Strzalkowski <contact@tedski.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# The complete text of the GNU General Public License can be found
# on the World Wide Web: <http://www.gnu.org/licenses/gpl.html/>
#
# slack irssi plugin
#
# A plugin to add functionality when dealing with Slack.
# See http://slack.com/ for details on what Slack is.
#
# usage:
#
# there are 2 settings available:
#
# /set slack_token <string>
#  - The api token from https://api.slack.com/
#
# /set slack_loglines <integer>
#  - the number of lines to grab from channel history
#

use 5.14;
use warnings;

use Irssi;
use Irssi::TextUI;
use JSON;
use URI;
use LWP::UserAgent;
use Mozilla::CA;
use POSIX qw(strftime);

our $VERSION = "0.1.1";
our %IRSSI = (
    authors => "Ted \'tedski\' Strzalkowski",
    contact => "contact\@tedski.net",
    name  => "slack",
    description => "Add functionality when connected to the Slack IRC Gateway.",
    license => "GPL",
    url   => "https://github.com/tedski/slack-irssi/",
    changed => "Wed, 13 Aug 2014 03:12:04 +0000"
);

my $baseurl = "https://slack.com/api/";

my $ua = LWP::UserAgent->new;
$ua->agent("$IRSSI{name} irssi/$VERSION");
$ua->timeout(3);
$ua->env_proxy;

sub is_slack_server {
    my ( $server ) = @_;

    return $server->{'address'} =~ /^\w+\.irc\.slack\.com/;
}

sub api_call {
  my ( $http_method, $api_method, %params ) = @_;

  my $uri = URI->new($baseurl . $api_method);
  my $token = Irssi::settings_get_str($IRSSI{'name'} . '_token');
  $url->query_form($url->query_form, %params, token => $token);

  my $req = HTTP::Request->new($http_method, $url);
  my $resp = $ua->request($req);
  my $payload = from_json($resp->decoded_content);
  if ($resp->is_success) {
    if (! $payload->{ok}) {
      Irssi::print("The Slack API returned the following error: $payload->{error}", MSGLEVEL_CLIENTERROR);
    } else {
      return $payload;
    }
  } else {
    Irssi::print("Error calling the slack api: $resp->{code} $resp->{message}", MSGLEVEL_CLIENTERROR);
  }
}

sub sig_server_conn {
  my ($server) = @_;

  return unless is_slack_server($server);
  Irssi::signal_add('channel joined', 'get_chanlog');
}

sub sig_server_disc {
  my ($server) = @_;

  return unless is_slack_server($server);

  Irssi::signal_remove('channel joined', 'get_chanlog');
}

sub get_users {
  state $users_cache;
  state $last_users_update = 0;

  return unless Irssi::settings_get_str($IRSSI{'name'} . '_token');

  if(($last_users_update + 4 * 60 * 60) < time()) {
    my $resp = api_call(GET => 'users.list');

    if($resp->{'ok'}) {
      $users_cache = {};
      my $slack_users = $resp->{'members'};
      foreach my $user (@$slack_users) {
        $users_cache->{ $u->{'id'} } = $u->{'name'};
      }
      $last_users_update = time();
    }
  }

  return $users_cache;
}

sub get_chanid {
  state $channel_cache;
  state $groups_cache;
  state $last_channels_update = 0;
  state $last_groups_update = 0;

  my ($channame, $is_private, $force) = @_;

  my $cache_ref       = \$channel_cache;
  my $last_update_ref = \$last_channels_update;

  my $resource = 'channels';
  if($is_private) {
    $resource       = 'groups';
    $cache_ref       = \$groups_cache;
    $last_update_ref = \$last_groups_update;
  }

  if($force || !exists(${$$cache_ref}{$channame}) || (($$last_update_ref + 4 * 60 * 60) < time())) {
    my $resp = api_call(GET => "$resource.list",
      exclude_archived => 1);

    if($resp->{'ok'}) {
      my $cache = {};
      foreach my $channel (@{ $resp->{$resource} }) {
        $cache->{ $channel->{'name'} } = $channel->{'id'};
      }
      $$last_update_ref = time();

      $$ccache_ref = $cache;
    }
  }

  return ${$$cache_ref}{$channame};
}

sub get_chanlog {
  my ($channel) = @_;

  return unless is_slack_server($channel->{'server'});

  my $users = get_users();

  my $count = Irssi::settings_get_int($IRSSI{'name'} . '_loglines');
  my $channel_name = $channel->{'name'} =~ s/^#//r;

  my $resp = api_call(GET => 'channels.history'
    channel => get_chanid($channel_name, 0, 0),
    count   => $count);

  if (!$resp->{ok}) {
    # First try failed, so maybe this chan is actually a private group
    Irssi::print($channel_name. " appears to be a private group");
    $resp = api_call(GET => 'groups.history',
      channel => $groupid,
      count   => $count);
  }

  if ($resp->{ok}) {
    my $msgs = $resp->{messages};
    foreach my $m (reverse(@{$msgs})) {
      if ($m->{type} eq 'message') {
        if ($m->{subtype} eq 'message_changed') {
          $m->{text} = $m->{message}->{text};
          $m->{user} = $m->{message}->{user};
        }
        elsif ($m->{subtype}) {
          next;
        }
        my $ts = strftime('%H:%M', localtime $m->{ts});
        $channel->printformat(MSGLEVEL_PUBLIC, 'slackmsg', $users->{$m->{'user'}}, $m->{'text'}, '+', $ts);
      }
    }
  }
}

sub update_slack_mark {
  state %last_mark_updated;

  my ($window) = @_;

  return unless ($window->{active}->{type} eq 'CHANNEL' &&
                 is_slack_server($window->{'active_server'}));
  return unless Irssi::settings_get_str($IRSSI{'name'} . '_token');

  # Leave $line set to the final visible line, not the one after.
  my $view = $window->view();
  my $line = $view->{startline};
  my $count = $view->get_line_cache($line)->{count};
  while ($count < $view->{height} && $line->next) {
    $line = $line->next;
    $count += $view->get_line_cache($line)->{count};
  }

  # Only update the Slack mark if the most recent visible line is newer.
  my($channel) = $window->{active}->{name} =~ /^#(.*)/;
  if ($last_mark_updated{$channel} < $line->{info}->{time}) {
    api_call(GET => 'channels.mark'
      channel => get_chanid($channel),
      ts      => $line->{'info'}{'time'});
    $last_mark_updated{$channel} = $line->{info}->{time};
  }
}

sub sig_window_changed {
  my ($new_window) = @_;
  update_slack_mark($new_window);
}

sub sig_message_public {
  my ($server, $msg, $nick, $address, $target) = @_;

  my $window = Irssi::active_win();
  if ($window->{active}->{type} eq 'CHANNEL' &&
      $window->{active}->{name} eq $target &&
      $window->{bottom}) {
    update_slack_mark($window);
  }
}

sub cmd_mark {
  my ($mark_windows) = @_;

  my(@windows) = Irssi::windows();
  my @mark_windows;
  foreach my $name (split(/\s+/, $mark_windows)) {
    if ($name eq 'ACTIVE') {
      push(@mark_windows, Irssi::active_win());
      next;
    }

    foreach my $window (@windows) {
      if ($window->{name} eq $name) {
        push(@mark_windows, $window);
      }
    }
  }
  foreach my $window (@mark_windows) {
    update_slack_mark($window);
  }
}

# themes
Irssi::theme_register(['slackmsg', '{timestamp $3} {pubmsgnick $2 {pubnick $0}}$1']);

# signals
Irssi::signal_add('server connected', 'sig_server_conn');
Irssi::signal_add('server disconnected', 'sig_server_disc');
Irssi::signal_add('setup changed', 'get_users');
Irssi::signal_add('window changed', 'sig_window_changed');
Irssi::signal_add('message public', 'sig_message_public');

Irssi::command_bind('mark', 'cmd_mark');

# settings
Irssi::settings_add_str('misc', $IRSSI{'name'} . '_token', '');
Irssi::settings_add_int('misc', $IRSSI{'name'} . '_loglines', 20);

# vim: sts=2 sw=2
