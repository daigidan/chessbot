# Introduction #

chessbot is Perl glue for playing chess over IRC with persistent games and stats.

# Installation #

chessbot currently has no makefile, so if you want to play with it you'll need to install the modules used in chessbot.pl, create a SQLite3 database using the included schema.sql, and configure it in chessbot.conf.

# Commands #

A note about game modes: chessbot can be configured to connect to zero or more channels. When games are initiated on these channels they become public and others can view information about them. When games are initiated via private messages they are, well, private to the players involved.

chessbot accepts the following commands via IRC:

  * `register` - send this command to the bot in a private message to register your nick for playing games. Note: chessbot doesn't perform any authentication, so if you care about your stats you should use a nick which is reserved with your IRC network.
  * `challenge [nick]` - send a challenge to _nick_ to play a game.
  * `accept `_`[challenge_id]`_ - accept the challenge identified by _challenge\_id_. If there is only one challenge open against you, you may omit _challenge\_id_.
  * `decline `_`[challenge_id]`_ - decline the challenge identified by _challenge\_id_. If there is only one challenge open against you, you may omit _challenge\_id_.
  * `show `_`[game_id]`_ - show the Forsyth–Edwards Notation (FEN) representation of the game identified by _game\_id_. The FEN can be viewed online using the many viewers available. A nice viewer can be found at: http://www.chess-poster.com/fen/epd_fen.htm. You may omit _game\_id_ if you are only playing one game.
  * `games` - list the games you are currently playing.
  * `moves `_`[game_id]`_ - List the moves for the game identified by _game\_id_.
  * `stats` - Show your stats, including your wins, losses, draws, and your Elo score. For more information on Elo scores, see: http://en.wikipedia.org/wiki/Elo_rating_system.
  * `challenges` - list challenges open against you.
  * `help` - get the URL for help.
  * _`[game_id]`_ `[move]` - Make a move in the game identified by _game\_id_, which can be omitted if you are only playing one game. Moves are specified in Standard Algebraic Notation (SAN). For more info on SAN, see: http://en.wikipedia.org/wiki/Algebraic_chess_notation.