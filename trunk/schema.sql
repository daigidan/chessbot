DROP TABLE players;
CREATE TABLE players (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nick TEXT NOT NULL UNIQUE,
  created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  wins INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  elo INTEGER NOT NULL DEFAULT 1600
);
CREATE TRIGGER fkd_players
BEFORE DELETE ON players
FOR EACH ROW BEGIN 
  DELETE FROM challenges WHERE challenger_id = OLD.id OR challengee_id = OLD.id;
  DELETE FROM games WHERE white_id = OLD.id OR black_id = OLD.id;
END;

DROP TABLE challenges;
CREATE TABLE challenges (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  challenger_id INTEGER REFERENCES players(id),
  challengee_id INTEGER REFERENCES players(id),
  mode TEXT NOT NULL,
  channel TEXT,
  created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved DATETIME,
  resolution TEXT
);

DROP TABLE games;
CREATE TABLE games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  challenge_id INTEGER REFERENCES challenges(id),
  white_id INTEGER REFERENCES players(id),
  black_id INTEGER REFERENCES players(id),
  to_move INTEGER REFERENCES players(id),
  half_move INTEGER DEFAULT 0,
  moves TEXT,
  state TEXT NOT NULL,
  created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  concluded DATETIME,
  channel TEXT,
  mode TEXT NOT NULL,
  result INTEGER
);
