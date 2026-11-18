# Wishes

- Allow a chat catch up for when someone mentioned you as "@nickname" while you
  were offline. The `nickname` is a choice of user, configurable by the user
  themself, from a list of aliases they're known as.
  - Needs a section in general settings:
    - option editbox - choose list of nicknames (comma separated, case
      insensitive).
    - option checkbox - notify upon login (with 10s delay to allow other addons
      to load)
  - Context: There is a gchat history in standard wow guild interface; But also
    we could sync guild chat across characters using the distributed sync db.
  - When a user types a message with a word starting with "@", and there's no
    witness online to copy from them, we print a warning - "no other players
    with addon online, your @mention is not propagated till another player comes
    online"