#!/usr/bin/perl

use strict;
use warnings;
use Chess::Rep;
use Chess::Elo qw(:all);
use Config::General;
use DBI;
use Log::Log4perl qw(:easy);
use POE qw(Component::IRC::State Component::IRC::Plugin::Connector);

# get logger
Log::Log4perl->easy_init($DEBUG);
my $logger = get_logger();

# get our config
my $conf = new Config::General('chessbot.conf')
  or $logger->logdie("[S] Could not read config file: $!");
my %config = $conf->getall;

# connect to db
my $db_args = {'AutoCommit' => 0, 'PrintError' => 1};
my $dbh = DBI->connect("dbi:SQLite:dbname=$config{'db_filename'}", '', '', $db_args)
  or $logger->logdie("[S] Could not connect to database: $!");

# prepare frequently-used statements
my %prepared = (
  'player' => prepare('SELECT * FROM players WHERE nick = ?'),
  'player_id' => prepare('SELECT * FROM players WHERE id = ?'),
  'challenge' => prepare('SELECT * FROM challenges WHERE id = ?'),
  'open_challenge' => prepare('SELECT * FROM challenges WHERE challenger_id = ? AND challengee_id = ? AND resolved IS NULL'),
  'open_challenges' => prepare('SELECT * FROM challenges WHERE challengee_id = ? AND resolved IS NULL'),
  'open_games' => prepare('SELECT * FROM games WHERE (white_id = ? OR black_id = ?) AND result IS NULL'),
  'game_id' => prepare('SELECT * FROM games WHERE id = ? AND result IS NULL'),
);

# connect to IRC
my ($irc) = POE::Component::IRC::State->spawn();
POE::Session->create(
  'inline_states' => {
    '_start' => \&bot_start,
    'irc_001' => \&on_connect,
    'irc_public' => \&on_public,
    'irc_msg' => \&on_private,
    'irc_error' => \&on_error,
    'irc_socketerr' => \&on_disconnect,
  },
  'package_states' => [ 
    'main' => [qw(bot_start lag_o_meter)],
  ],
);

# handlers
sub bot_start {
  my $kernel  = $_[KERNEL];
  my $heap    = $_[HEAP];
  my $session = $_[SESSION];
  $heap->{'connector'} = POE::Component::IRC::Plugin::Connector->new();
  $irc->plugin_add( 'Connector' => $heap->{'connector'});
  $irc->yield('register' => 'all');
  $irc->yield('connect' => {
    'Nick' => $config{'nick'},
    'Username' => $config{'nick'},
    'Ircname' => $config{'nick'},
    'Server' => $config{'server'},
    'Port' => $config{'port'},
    'Debug' => $config{'debug'}
  });
  $kernel->delay('lag_o_meter' => 60);
}

sub lag_o_meter {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  $kernel->delay('lag_o_meter' => 60);
  return;
}

sub on_connect {
  my ($kernel, $sender, $message, $message2) = @_[KERNEL, SENDER, ARG0, ARG1];
  $logger->info("[S] Connected to $message");
  $logger->info("[S] $message2");

  if ($config{'authserv'}) {
    $irc->yield('privmsg' => $config{'authserv'} => "AUTH $config{'pass'}");
  }

  $logger->info('[S] Joining channels...');
  my @channels = split(/ /, $config{'channels'});
  foreach my $channel (@channels) {
    $channel = '#' . $channel;
    $logger->info("[S]    $channel");
    $irc->yield('join' => $channel);
  }
  $logger->info('[S] Done joining channels');
}

sub on_error {
  my ($kernel, $sender, $error) = @_[KERNEL, SENDER, ARG0];
  $logger->error("[S] $error");
}

sub on_disconnect {
  my ($kernel, $sender, $error) = @_[KERNEL, SENDER, ARG0];
  $logger->logdie("[S] $error");
}

sub on_private {
  my ($kernel, $sender, $who, $where, $msg) = @_[KERNEL, SENDER, ARG0, ARG1, ARG2];
  my $nick = (split(/!/, $who))[0];
  my $channel = $where->[0];
  $logger->info("[M] <$nick:$channel> $msg");

  if ($msg =~ m/^challenge (\w+)$/) {
    issue_challenge($nick, $1, undef, 'private');
  } elsif ($msg =~ m/^accept (\d+)$/) {
    accept_challenge_id($nick, $1);
  } elsif ($msg =~ m/^accept$/) {
    accept_challenge($nick);
  } elsif ($msg =~ m/^decline (\d+)$/) {
    decline_challenge_id($nick, $1);
  } elsif ($msg =~ m/^decline$/) {
    decline_challenge($nick);
  } elsif ($msg =~ m/^show (\d+)$/) {
    show_game_id($nick, $1);
  } elsif ($msg =~ m/^show$/) {
    show_game($nick);
  } elsif ($msg =~ m/^games$/) {
    list_games($nick);
  } elsif ($msg =~ m/^moves (\d+)$/) {
    show_moves($nick, $1);
  } elsif ($msg =~ m/^stats$/) {
    show_stats($nick);
  } elsif ($msg =~ m/^challenges$/) {
    list_challenges($nick);
  } elsif ($msg =~ m/^register$/) {
    register_player($nick);
  } elsif ($msg =~ m/^help$/) {
    show_help($nick);
  } elsif ($msg =~ m/^(\d+) (\S+)$/) {
    make_move_in_game($nick, $1, $2);
  } elsif ($msg =~ m/^(\S+)$/) {
    make_move($nick, $1);
  } else {
    $irc->yield('privmsg' => $nick => "Invalid command. Type 'help' for usage.");
  }
}

sub on_public ($$) {
  my ($kernel, $sender, $who, $where, $msg) = @_[KERNEL, SENDER, ARG0, ARG1, ARG2];
  my $nick = (split(/!/, $who))[0];
  my $channel = $where->[0];

  if ($msg =~ m/^$config{'nick'} (.*)$/) {
    my $command = $1;
    $logger->info("[M] <$nick:$channel> $msg");
    if ($command =~ m/^challenge (\w+)$/) {
      issue_challenge($nick, $1, $channel, "public");
    } elsif ($command =~ m/^accept (\d+)$/) {
      accept_challenge_id($nick, $1);
    } elsif ($command =~ m/^accept$/) {
      accept_challenge($nick);
    } elsif ($command =~ m/^decline (\d+)$/) {
      decline_challenge_id($nick, $1);
    } elsif ($command =~ m/^decline$/) {
      decline_challenge($nick);
    } elsif ($command =~ m/^show (\d+)$/) {
      show_game_id($nick, $1);
    } elsif ($command =~ m/^show$/) {
      show_game($nick);
    } elsif ($command =~ m/^games$/) {
      list_games($nick);
    } elsif ($command =~ m/^moves (\d+)$/) {
      show_moves($nick, $1);
    } elsif ($command =~ m/^stats$/) {
      show_stats($nick);
    } elsif ($command =~ m/^challenges$/) {
      list_challenges($nick);
    } elsif ($command =~ m/^help$/) {
      show_help($nick);
    } elsif ($command =~ m/^game (\d+) ([private|public])$/) {
      change_mode($nick, $1, $2);
    } elsif ($command =~ m/^(\d+) (\S+)$/) {
      make_move_in_game($nick, $1, $2);
    } elsif ($command =~ m/^(\S+)$/) {
      make_move($nick, $1);
    } else {
      $irc->yield('privmsg' => $nick => "Invalid command. Type 'help' for usage.");
    }
  }
}
# end handlers

# begin subs

# prepare a DBI statement
sub prepare {
  my $stmt = shift;
  my $sth = $dbh->prepare($stmt)
    or $logger->logdie('[S] Could not prepare statement: ' . $dbh->errstr);
  return $sth;
}

# DBI do()
sub do_stmnt {
  my ($stmnt, @bind_values) = @_;
  $dbh->do($stmnt, undef, @bind_values)
    or $logger->logdie('[S] Could not do statement: ' . $dbh->errstr);
}

# execute a prepared DBI statement
sub execute_prepared {
  my ($sth_name, @bind_values) = @_;
  my $sth = $prepared{$sth_name};
  $sth->execute(@bind_values)
    or $logger->logdie('[S] Could not execute statement: ' . $sth->errstr);
  return $sth;
}

# check if player is registered
sub is_registered {
  my $nick = shift;
  my $sth = execute_prepared('player', $nick);

  my $row = $sth->fetchrow_hashref();
  if (defined($row)) {
    return $row;
  } else {
    return;
  }
}

# register a player
sub register_player {
  my $nick = shift;
  if (!is_registered($nick)) {
    do_stmnt('INSERT INTO players (nick) VALUES (?)', $nick);
    $dbh->commit();
    $logger->info("[A] '$nick' registered.");
    $irc->yield(privmsg => $nick => "Registration successful. Type 'help' to get started.");
  } else {
    $irc->yield(privmsg => $nick => "'$nick' is already registered.");
  }
}

# convenience command for when a player is only playing one game
sub make_move {
  my ($nick, $move) = @_;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # find open games for requestor; there should be only one
  my $open_games = (execute_prepared('open_games', $player_row->{'id'}, $player_row->{'id'}))->fetchall_arrayref({});
  if (@$open_games == 1) {
    make_move_in_game($nick, $open_games->[0]{'id'}, $move);
  } elsif (@$open_games > 1) {
    $irc->yield('privmsg' => $nick => "You are playing multiple games. Type 'games' to list them.");
  } else {
    $irc->yield('privmsg' => $nick => "You are not playing any games. Type 'help' to get started.");
  }
}

# make a move in game identified by id
sub make_move_in_game {
  my ($nick, $game_id, $move) = @_;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # get game
  my $game_row = (execute_prepared('game_id', $game_id))->fetchrow_hashref();

  # valid game?
  unless ($game_row) {
    $irc->yield('privmsg' => $nick => 'Invalid game id.');
    return;
  }

  # valid player for this game?
  unless (($game_row->{'white_id'} == $player_row->{'id'})
    || ($game_row->{'black_id'} == $player_row->{'id'})) {
    $irc->yield('privmsg' => $nick => 'You are not a player in this game.');
    return;
  }

  # is it this player's turn?
  unless ($game_row->{'to_move'} == $player_row->{'id'}) {
    $irc->yield('privmsg' => $nick => "[$game_row->{'id'}] It is not your turn.");
    return;
  }

  # load game
  $game_id = $game_row->{'id'};
  my $game = Chess::Rep->new($game_row->{'state'});

  # choose destination for messages
  my $msg_dest = $game_row->{'mode'} eq 'public' ? $game_row->{'channel'} : $nick;

  # make move
  eval {
    $move = $game->go_move($move);
  };
  if ($@) {
    $irc->yield('privmsg' => $msg_dest => "[$game_row->{'id'}] Invalid move.");
    return;
  }

  # get other player
  my $other_player_row;
  if ($game_row->{'white_id'} == $player_row->{'id'}) {
    $other_player_row = (execute_prepared('player_id', $game_row->{'black_id'}))->fetchrow_hashref();
  } else {
    $other_player_row = (execute_prepared('player_id', $game_row->{'white_id'}))->fetchrow_hashref();
  }

  # update move list
  my $moves = $game_row->{'moves'};
  my $half_move = $game_row->{'half_move'} + 1;
  if ($half_move % 2) {
    $moves .= (int($half_move / 2) + 1) . ". $move->{'san'} ";
  } else {
    $moves .= "$move->{'san'} ";
  }

  # is game over?
  if ($game->status->{'mate'}) {
    # result is from white's perspective
    my $result = $game_row->{'white_id'} == $player_row->{'id'} ? 1 : -1;

    # calculate new Elo scores
    my ($player_elo, $other_player_elo) = elo($player_row->{'elo'}, 1, $other_player_row->{'elo'});

    # closeout game
    do_stmnt(qq{
      UPDATE games SET state = ?, result = ?, half_move = ?, moves = ?, concluded = CURRENT_TIMESTAMP WHERE id = ?
    }, $game->get_fen(), $result, $half_move, $moves, $game_id);

    # update player stats
    do_stmnt(qq{
      UPDATE players SET wins = ?, elo = ? WHERE id = ?
    }, $player_row->{'wins'} + 1, $player_elo, $player_row->{'id'});
    do_stmnt(qq{
      UPDATE players SET losses = ?, elo = ? WHERE id = ?
    }, $other_player_row->{'losses'} + 1, $other_player_elo, $other_player_row->{'id'});
    $logger->info("[A] $player_row->{'nick'} mated $other_player_row->{'nick'}");

    # inform player
    $irc->yield('privmsg' => $msg_dest => "[$game_id] Checkmate.");
  } elsif ($game->status->{'stalemate'}) {
    # calculate new Elo scores
    my ($player_elo, $other_player_elo) = elo($player_row->{'elo'}, .5, $other_player_row->{'elo'});

    # closeout game
    do_stmnt(qq{
      UPDATE games SET state = ?, result = ?, half_move = ?, moves = ?, concluded = CURRENT_TIMESTAMP WHERE id = ?
    }, $game->get_fen(), 0, $half_move, $moves, $game_id);
 
    # update player stats
    do_stmnt(qq{
      UPDATE players SET draws = ?, elo = ? WHERE id = ?
    }, $player_row->{'draws'} + 1, $player_elo, $player_row->{'id'});
    do_stmnt(qq{
      UPDATE players SET draws = ?, elo = ? WHERE id = ?
    }, $other_player_row->{'draws'} + 1, $other_player_elo, $other_player_row->{'id'});
    $logger->info("[A] stalemate between $player_row->{'nick'} and $other_player_row->{'nick'}");

    # inform player
    $irc->yield('privmsg' => $msg_dest => "[$game_id] Stalemate.");
  } else {
    # update game state
    do_stmnt(qq{UPDATE games SET state = ?, to_move = ?, half_move = ?, moves = ? WHERE id = ?
    }, $game->get_fen(), $other_player_row->{'id'}, $half_move, $moves, $game_id);

    # inform player if check
    if ($game->status->{'check'}) {
      $irc->yield('privmsg' => $msg_dest => "[$game_id] $other_player_row->{'nick'} is in check.");
    }
  }
  $irc->yield('privmsg' => $other_player_row->{'nick'} => "[$game_id] $player_row->{'nick'} moves $move->{'san'}");
  $dbh->commit();
}

# issue a challenge from one player to another
sub issue_challenge {
  my ($challenger, $challengee, $channel, $mode) = @_;
  
  # basic sanity checks
  if ($challenger eq $challengee) {
    $irc->yield('privmsg' => $challenger => 'You cannot challenge yourself.');
    return;
  }
  if ($challengee eq $config{'nick'}) {
    $irc->yield('privmsg' => $challenger => "You cannot challenge $config{'nick'}.");
    return;
  }

  # check player registration 
  my $challenger_row = is_registered($challenger);
  my $challengee_row = is_registered($challengee);
  unless ($challenger_row) {
    $irc->yield('privmsg' => $challenger => "You are not registered. Type 'help' to get started.");
    return;
  }
  unless ($challengee_row) {
    $irc->yield('privmsg' => $challenger => "$challengee is not registered.");
    return;
  }

  my $challenger_id = $challenger_row->{'id'};
  my $challengee_id = $challengee_row->{'id'};

  # check for existing challenge from challenger to challengee or vice versa
  my $existing_challenge = (execute_prepared('open_challenge', $challenger_id, $challengee_id))->fetchall_arrayref();
  my $existing_challenged = (execute_prepared('open_challenge', $challengee_id, $challenger_id))->fetchall_arrayref();
  if (@$existing_challenge || @$existing_challenged) {
    $irc->yield('privmsg' => $challenger => "You have a challenge open with this player already. Type 'challenges' to list challenges.");
    return;
  }

  # check that a game is not already in progress
  my $open_games = (execute_prepared('open_games', $challenger_id, $challenger_id))->fetchall_arrayref({});
  for (my $i = 0; $i < @$open_games; $i++) {
    if ($open_games->[$i]{'white_id'} == $challengee_id || $open_games->[$i]{'black_id'} == $challengee_id) {
      $irc->yield('privmsg' => $challenger => "You are already playing a game with this player. Type 'games' to list games.");
      return;
    }
  }

  # was this challenge made in public or private?
  if ($mode eq 'public') {
    do_stmnt(q{
      INSERT INTO challenges (challenger_id, challengee_id, mode, channel) VALUES (?, ?, ?, ?)
    }, $challenger_id, $challengee_id, $mode, $channel);
    $dbh->commit();
    $logger->info("[A] $challenger challenged $challengee");
    $irc->yield('privmsg' => $channel => "$challenger challenges $challengee to a game of chess.");
  } else {
    do_stmnt(q{
      INSERT INTO challenges (challenger_id, challengee_id, mode) VALUES (?, ?, ?)
    }, $challenger_id, $challengee_id, $mode);
    $dbh->commit();
    $logger->info("[A] $challenger challenged $challengee");
    $irc->yield('privmsg' => $challengee => "$challenger has challenged you to a game of chess.");
    $irc->yield('privmsg' => $challenger => "Challenge sent to $challengee.");
  }
}

# convenience command for accepting a challenge
# when a player only has one open challenge against them
sub accept_challenge {
  my $nick = shift;

  # check player registration
  my $challengee_row = is_registered($nick);
  unless ($challengee_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # look for open challenges
  my $challenges = (execute_prepared('open_challenges', $challengee_row->{'id'}))->fetchall_arrayref({'id' => 1});
  if (@$challenges == 1) {
    accept_challenge_id($nick, $challenges->[0]{'id'});
  } elsif (@$challenges > 1) {
    $irc->yield('privmsg' => $nick => "You have multiple challenges open. Type 'challenges' to list them.");
  } else {
    $irc->yield('privmsg' => $nick => 'You have no challenges open against you.');
  }
}

# accept a challenge from another player
sub accept_challenge_id {
  my ($nick, $challenge_id) = @_;

  my $challenge = valid_challenge($nick, $challenge_id);
  if ($challenge) {
    # get challenger nick
    my $challenger_row = (execute_prepared('player_id', $challenge->{'challenger_id'}))->fetchrow_hashref();
    my $challengee_row = (execute_prepared('player_id', $challenge->{'challengee_id'}))->fetchrow_hashref();
    my $challenger_id = $challenger_row->{'id'};
    my $challengee_id = $challengee_row->{'id'};
    my $challenger_nick = $challenger_row->{'nick'};
    my $challengee_nick = $challengee_row->{'nick'};
    my $channel = $challenge->{'channel'};

    # closeout challenge
    do_stmnt(qq{
      UPDATE challenges SET resolved = CURRENT_TIMESTAMP, resolution = 'accepted' WHERE id = $challenge_id
    });
    $logger->debug("[A] $challengee_nick accepted challenge from $challenger_nick");
 
    # create new game
    my $game = Chess::Rep->new();
    my $moves = "$challenger_nick vs. $challengee_nick ";

    # create game and inform players based on game mode
    if ($challenge->{'mode'} eq 'public') {
      do_stmnt(q{
        INSERT INTO games (challenge_id, white_id, black_id, to_move, moves, state, channel, mode)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
      }, $challenge_id, $challenger_id, $challengee_id, $challenger_id, $moves, $game->get_fen(), $channel, 'public');
      $dbh->commit();
      $logger->info("[A] new game between $challenger_nick and $challengee_nick");
      $irc->yield('privmsg' => $channel => "$challengee_nick accepted challenge from $challenger_nick. $challenger_nick to move.");
    } else {
      do_stmnt(q{
        INSERT INTO games (challenge_id, white_id, black_id, to_move, moves, state, mode)
        VALUES(?, ?, ?, ?, ?, ?, ?)
      }, $challenge_id, $challenger_id, $challengee_id, $challenger_id, $moves, $game->get_fen(), 'private');
      $dbh->commit();
      $logger->info("[A] new game between $challenger_nick and $challengee_nick");
      $irc->yield('privmsg' => $challengee_nick => "Challenge accepted. $challenger_nick to move.");
      $irc->yield('privmsg' => $challenger_nick => "$challengee_nick has accepted your challenge. It is your turn to move.");
    }
  }
}

# convenience command for declining a challenge
# when player has only one open challenge
sub decline_challenge {
  my $nick = shift;

  # check player registration
  my $challengee_row = is_registered($nick);
  unless ($challengee_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # look for open challenges
  my $challenges = (execute_prepared('open_challenges', $challengee_row->{'id'}))->fetchall_arrayref({'id' => 1});
  if (@$challenges == 1) {
    decline_challenge_id($nick, $challenges->[0]{'id'});
  } elsif (@$challenges > 1) {
    $irc->yield('privmsg' => $nick => "You have multiple challenges open. Type 'challenges' to list them.");
  } else {
    $irc->yield('privmsg' => $nick => 'You have no challenges open against you.');
  }
}

# decline a challenge
sub decline_challenge_id {
  my ($nick, $challenge_id) = @_;

  my $challenge = valid_challenge($nick, $challenge_id);
  if ($challenge) {
    # get challenger nick
    my $challenger_row = (execute_prepared('player_id', $challenge->{'challenger_id'}))->fetchrow_hashref();

    # closeout challenge
    do_stmnt(qq{
      UPDATE challenges SET resolved = CURRENT_TIMESTAMP, resolution = 'declined' WHERE id = $challenge_id
    });
    $dbh->commit();
    $logger->debug("[A] $nick declined $challenger_row->{'nick'}'s challenge");

    # notify players
    $irc->yield('privmsg' => $nick => 'Challenge declined.');
    $irc->yield('privmsg' => $challenger_row->{'nick'} => "$nick has declined your challenge.");
  }
}

# helper to validate a challenge
sub valid_challenge {
  my ($nick, $challenge_id) = @_;

  # check player registration
  my $challengee_row = is_registered($nick);
  unless ($challengee_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # check challenge
  my $challenge = (execute_prepared('challenge', $challenge_id))->fetchrow_hashref();
  unless (defined($challenge)) {
    $irc->yield('privmsg' => $nick => 'Invalid challenge id.');
    return;
  }
  if ($challenge->{'resolved'}) {
    $irc->yield('privmsg' => $nick => 'This challenge is closed.');
    return;
  }

  # is requestor the challengee?
  unless ($challenge->{'challengee_id'} == $challengee_row->{'id'}) {
    $irc->yield('privmsg' => $nick => 'You are not the challengee for this challenge id.');
    return;
  }

  return $challenge;
}

# convenience command for showing a game
# when a player is only playing one game
sub show_game {
  my $nick = shift;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # look for open games
  my $open_games = (execute_prepared('open_games', $player_row->{'id'}, $player_row->{'id'}))->fetchall_arrayref({});
  if (@$open_games == 1) {
    show_game_id($nick, $open_games->[0]{'id'});
  } elsif (@$open_games > 1) {
    $irc->yield('privmsg' => $nick => "You are currently playing multiple games. Type 'games' to list them.");
  } else {
    $irc->yield('privmsg' => $nick => 'You are not currently playing any games.');
  }
}

# show a game based on its id
sub show_game_id {
  my ($nick, $game_id) = @_;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # get game
  my $game_row = (execute_prepared('game_id', $game_id))->fetchrow_hashref();

  # valid game?
  unless ($game_row) {
    $irc->yield('privmsg' => $nick => 'Invalid game id.');
    return;
  }

  # if this is a private game, check that requestor is playing
  if ($game_row->{'mode'} eq 'private') {
    unless ($game_row->{'white_id'} == $player_row->{'id'} || $game_row->{'black_id'} == $player_row->{'id'}) {
      $irc->yield('privmsg' => $nick => 'This is a private game.');
      return;
    }
  }

  # load game and send FEN
  my $game = Chess::Rep->new($game_row->{'state'});
  $irc->yield('privmsg' => $nick => "[$game_row->{'id'}] " . $game->get_fen());
}

# list open games
sub list_games {
  my $nick = shift;
  
  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }
 
  my $open_games = (execute_prepared('open_games', $player_row->{'id'}, $player_row->{'id'}))->fetchall_arrayref({});
  if (@$open_games == 0) {
    $irc->yield('privmsg' => $nick => 'You are not playing any games.');
  } else {
    my $games = '';
    for (my $i = 0; $i < @$open_games; $i++) {
      my $other_player_row;
      if ($player_row->{'id'} == $open_games->[$i]{'white_id'}) {
        $other_player_row = (execute_prepared('player_id', $open_games->[$i]{'black_id'}))->fetchrow_hashref();
      } else {
        $other_player_row = (execute_prepared('player_id', $open_games->[$i]{'white_id'}))->fetchrow_hashref();
      }
      $games .= "[" . $open_games->[$i]{'id'} . "] $other_player_row->{'nick'} ";
    }
    $irc->yield('privmsg' => $nick => $games);
  }
}

# show move list for a game
sub show_moves {
  my ($nick, $game_id) = @_;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  # get game
  my $game_row = (execute_prepared('game_id', $game_id))->fetchrow_hashref();

  # valid game?
  unless ($game_row) {
    $irc->yield('privmsg' => $nick => 'Invalid game id.');
    return;
  }

  # if this is a private game, check that requestor is playing
  if ($game_row->{'mode'} eq 'private') {
    unless ($game_row->{'white_id'} == $player_row->{'id'} || $game_row->{'black_id'} == $player_row->{'id'}) {
      $irc->yield('privmsg' => $nick => 'This is a private game.');
      return;
    }
  }

  $irc->yield('privmsg' => $nick => "[$game_row->{'id'}] $game_row->{'moves'}");
}

# show player stats
sub show_stats {
  my $nick = shift;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  my $stats = 'Wins: ' . $player_row->{'wins'} . ' Losses: ' . $player_row->{'losses'} . ' Draws: ' . $player_row->{'draws'} . ' Elo: ' . $player_row->{'elo'};
  $irc->yield('privmsg' => $nick => $stats);
}

# list open challenges
sub list_challenges {
  my $nick = shift;

  # check player registration
  my $player_row = is_registered($nick);
  unless ($player_row) {
    $irc->yield('privmsg' => $nick => "You are not registered. Type 'help' to get started.");
    return;
  }

  my $open_challenges = (execute_prepared('open_challenges', $player_row->{'id'}))->fetchall_arrayref({'id' => 1});
  if (@$open_challenges == 0) {
    $irc->yield('privmsg' => $nick => 'You have no challenges open against you.');
  } else {
    my $challenges = '';
    for (my $i = 0; $i < @{$open_challenges}; $i++) {
      my $other_player_row;
      if ($player_row->{'id'} == $open_challenges->[$i]{'challenger_id'}) {
        $other_player_row = (execute_prepared('player_id', $open_challenges->[$i]{'challengee_id'}))->fetchrow_hashref();
      } else {
        $other_player_row = (execute_prepared('player_id', $open_challenges->[$i]{'challenger_id'}))->fetchrow_hashref();
      }
      $challenges .= "[" . $open_challenges->[$i]{'id'} . "] $other_player_row->{'nick'} ";
    }
    $irc->yield('privmsg' => $nick => $challenges);
  }
}

# send help link
sub show_help {
  my $nick = shift;
  $irc->yield('privmsg' => $nick => $config{'helpurl'});
}

$poe_kernel->run();
$dbh->disconnect();
exit 0;
