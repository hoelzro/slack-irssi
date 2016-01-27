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

use v5.14.0;
use warnings;

use Irssi;
use Irssi::TextUI;
use JSON;
use URI;
use LWP::UserAgent;
use Mozilla::CA;
use POSIX qw(strftime);

our $VERSION = '0.1.1';
our %IRSSI = (
    authors     => q{Ted 'tedski' Strzalkowski},
    contact     => 'contact@tedski.net',
    name        => 'slack',
    description => 'Add functionality when connected to the Slack IRC Gateway.',
    license     => 'GPL',
    url         => 'https://github.com/tedski/slack-irssi/',
    changed     => 'Wed, 13 Aug 2014 03:12:04 +0000'
);

my $baseurl = 'https://slack.com/api/';

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

  my $uri   = URI->new($baseurl . $api_method);
  my $token = Irssi::settings_get_str($IRSSI{'name'} . '_token');
  $uri->query_form($uri->query_form, %params, token => $token);

  my $req     = HTTP::Request->new($http_method, $uri);
  my $resp    = $ua->request($req);
  my $payload = from_json($resp->decoded_content);

  if($resp->is_success) {
    if(! $payload->{'ok'}) {
      Irssi::print("The Slack API returned the following error: $payload->{'error'}", MSGLEVEL_CLIENTERROR);
    } else {
      return $payload;
    }
  } else {
    Irssi::print("Error calling the slack api: $resp->{'code'} $resp->{'message'}", MSGLEVEL_CLIENTERROR);
  }
}

sub sig_server_conn {
  my ( $server ) = @_;

  return unless is_slack_server($server);
  Irssi::signal_add('channel joined', 'get_chanlog');
}

sub sig_server_disc {
  my ( $server ) = @_;

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
        $users_cache->{ $user->{'id'} } = $user->{'name'};
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
  state $last_groups_update   = 0;

  my ( $channame, $is_private, $force ) = @_;

  my $cache_ref       = \$channel_cache;
  my $last_update_ref = \$last_channels_update;

  my $resource = 'channels';
  if($is_private) {
    $resource        = 'groups';
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

      $$cache_ref = $cache;
    }
  }

  return ${$$cache_ref}{$channame};
}

sub get_channel_history {
  my ( $channel_name, $count ) = @_;

  my $resp = api_call(GET => 'channels.history',
    channel => get_chanid($channel_name, 0, 0),
    count   => $count);

  return $resp->{'ok'} ? $resp->{'messages'} : undef;
}

sub get_group_history {
  my ( $channel_name, $count ) = @_;

  my $resp = api_call(GET => 'groups.history',
    channel => get_chanid($channel_name, 1, 0),
    count   => $count);

  return $resp->{'ok'} ? $resp->{'messages'} : undef;
}

sub get_im_history {
  my ( $channel_name, $count ) = @_;

  return; # XXX NYI

  # XXX find direct message ID (D...) given username ($channel_name)

=pod
  my $resp = api_call(GET => 'im.history',
    channel => $user_id,
    count   => $count);

  return $resp->{'ok'} ? $resp->{'messages'} : undef;
=cut
}

sub get_chanlog {
  my ( $channel ) = @_;

  return unless is_slack_server($channel->{'server'});

  my $users = get_users();

  my $count        = Irssi::settings_get_int($IRSSI{'name'} . '_loglines');
  my $channel_name = $channel->{'name'} =~ s/^#//r;

  my $messages;

  if(is_channel($channel_name)) {
    $messages = get_channel_history($channel_name, $count);
  } elsif(is_private_group($channel_name)) {
    $messages = get_group_history($channel_name, $count);
  } else { # it's an IM
    $messages = get_im_history($channel_name, $count);
  }

  return unless $messages;

  for my $message (reverse @$messages) {
    next unless $message->{'type'} eq 'message';

    my ( $text, $user );

    if($message->{'subtype'} eq 'message_changed') {
      ( $text, $user ) = @{ $message->{'message'} }{qw/text user/};
    } elsif(!$message->{'subtype'}) {
      ( $text, $user ) = @{$message}{qw/text user/};
    }

    $user = $users->{$user};

    my $ts = strftime('%H:%M', localtime $message->{'ts'});
    $channel->printformat(MSGLEVEL_PUBLIC, 'slackmsg', $user, $text, '+', $ts);
  }
}

sub update_slack_mark {
  state %last_mark_updated;

  my ( $window ) = @_;

  return unless($window->{'active'}{'type'} eq 'CHANNEL' &&
                 is_slack_server($window->{'active_server'}));
  return unless Irssi::settings_get_str($IRSSI{'name'} . '_token');

  # Leave $line set to the final visible line, not the one after.
  my $view  = $window->view();
  my $line  = $view->{'startline'};
  my $count = $view->get_line_cache($line)->{'count'};
  while($count < $view->{'height'} && $line->next) {
    $line = $line->next;
    $count += $view->get_line_cache($line)->{'count'};
  }

  # Only update the Slack mark if the most recent visible line is newer.
  my ( $channel ) = $window->{'active'}{'name'} =~ /^#(.*)/;
  if($last_mark_updated{$channel} < $line->{'info'}{'time'}) {
    api_call(GET => 'channels.mark',
      channel => get_chanid($channel),
      ts      => $line->{'info'}{'time'});
    $last_mark_updated{$channel} = $line->{'info'}{'time'};
  }
}

sub sig_window_changed {
  my ( $new_window ) = @_;
  update_slack_mark($new_window);
}

sub sig_message_public {
  my ( $server, $msg, $nick, $address, $target ) = @_;

  my $window = Irssi::active_win();
  if($window->{'active'}{'type'} eq 'CHANNEL' &&
      $window->{'active'}{'name'} eq $target &&
      $window->{'bottom'}) {
    update_slack_mark($window);
  }
}

sub cmd_mark {
  my ( $mark_windows ) = @_;

  my %mark_me = map { $_ => undef } split /\s+/, $mark_windows;

  if(exists $mark_me{'ACTIVE'}) {
    $mark_me{'ACTIVE'} = Irssi::active_win();
  }

  for my $window (Irssi::windows()) {
    my $name = $window->{'name'};
    next unless exists $mark_me{$name};

    $mark_me{$name} = $window;
  }

  for my $window (grep { defined() } values %mark_me) {
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

# don't display history messages that I've already received (where shall I store this info? logs?)
# expand U123456 etc in history messages (https://api.slack.com/docs/formatting)
# https://github.com/tedski/slack-irssi/issues/5
# https://github.com/tedski/slack-irssi/pull/15
# https://github.com/tedski/slack-irssi/issues/16
# ditch slackmsg theme?
# update changed date in %IRSSI
# bump VERSION

# vim: sts=2 sw=2
