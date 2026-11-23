# Wishes

## A State-provided Alias for Mains and Alts (codename: Teams)

- Addon installed on an account has a randomly generated unique account-ID.
- This account-ID will be used to assign an alias, "known as", a short name to
  display in guild chat every time a player speaks.
  - PROBLEM: Players without addon have no unique ID, and should be identified
    by either WoW playerID or their character names solely. Such players are
    grouped by officers manually using UI described below.
- Teams of alts (character-teams) can be created containing one or more these
  account-IDs to and character names, and will be used to identify a person
  behind them. Officers create these manually.
  - A data structure of `CharacterTeam` contains a list of account-IDs (used for
    detection only), and a list of character names. Account-ID and a character
    name can only belong to a single character-team.
  - A checkbox where an officer can deny the player using their own submitted
    alias, and use state-provided (added by the officer) alias, in case they're
    misbehaving and using foul language. In such case the display label
    propagated to all guild members will be the one added by the officer, not
    the one submitted by the player.
  - A character-team has an alias (short string) assigned to it, which is used
    to display the person behind the character or their main name. A player
    belonging to the character-team can change this alias.
  - Officers can assign a character to a character-team, or merge
    character-teams together, or break a character-team and remake it. Can move
    between character-teams only if account-ID will move with the character and
    will not create duplication in two character-teams (unique account-ID
    belongs to only one team requirement)
- Roster view inside OOOO addon (officer only) - a new tab with Crown symbol in
  its name
  - All online players are listed with their online status (grey if offline) and
    class color.
  - Clicked and selected player has a 25% silver background in the list.
  - Right panel shows details of that player's character-team (alias and team
    members).
  - Team creation is initiated manually by clicking a button in player's team
    detail panel and then selecting a character to group them to.
    - If any character is a member of a team, then they are grouped together.
    - If neither character has a team, a new one is created, and the officer is
      asked for a name.
    - If both have some teams already, then selected character can either move
      into the new team, or merge teams.  
- Permissions
  - Officers control the database of teams, players can only read from it.
  - Officers control the database of aliases, players can only read from it.
  - Updates to player's own team alias can be submitted by the player themselves
    (only if the submitting character is already in the character-team). Such
    update will go through an online officer and be written by the officer.
- Display in chat
  - Guild chat, officer chat (if possible), say, party, and whisper channels
    will detect the name in the square brackets, search the lookup table of
    teams, and display team alias if found: Example: `[Nota Tall] nota: hello`