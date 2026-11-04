program test_notifications;

{$mode objfpc}{$H+}{$codepage utf8}

uses
  cthreads, SysUtils, Classes, IniFiles, sqlite3dyn,
  notification_filters, event_scanner, database_watch;

var
  Db: psqlite3;
  Filters: TNotificationFilters;
  Delivered: Integer;
  Online: Boolean = True;
  LastBody, LastContact: string;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then raise Exception.Create(Msg);
end;

procedure Exec(const SQL: string);
begin
  if sqlite3_exec(Db, PChar(SQL), nil, nil, nil) <> SQLITE_OK then
    raise Exception.Create(string(sqlite3_errmsg(Db)));
end;

procedure AddEvent(const Sender, Channel, Body: string; Outgoing: Integer = 0);
begin
  Exec('INSERT INTO Events(remote_uid,channel,free_text,outgoing) VALUES(' +
    QuotedStr(Sender) + ',' + QuotedStr(Channel) + ',' + QuotedStr(Body) + ',' +
    IntToStr(Outgoing) + ')');
end;

function ReceiveEvent(const Event: TMessageEvent): Boolean;
var
  Index: Integer;
begin
  Result := Online;
  if not Online then Exit;
  if not Filters.ShouldShow(Event.Sender, Event.Channel, Event.Body, Index) then Exit;
  Inc(Delivered);
  LastBody := Event.Body;
  LastContact := Event.Contact;
  Filters.MarkShown(Index, Event.Sender, Event.Channel);
end;

procedure TestFilters;
var
  Config: TMemIniFile;
  Index: Integer;
  Failed: Boolean;
begin
  Config := TMemIniFile.Create('');
  try
    Config.WriteString('filter.omemo', 'body_contains', 'OMEMO');
    Config.WriteString('filter.omemo', 'action', 'once_per_contact');
    Config.WriteString('filter.spam', 'body_contains', 'buy now');
    Config.WriteString('filter.sender', 'sender', 'blocked@example.org');
    Config.WriteString('filter.channel', 'channel', 'muted-channel');
    Filters.Load(Config);
    Check(Filters.ShouldShow('alice', '', 'An omemo warning', Index), 'first warning');
    Check(Filters.ShouldShow('alice', '', 'An omemo warning', Index), 'failed sends must not count');
    Filters.MarkShown(Index, 'alice', '');
    Check(not Filters.ShouldShow('alice', '', 'different OMEMO warning', Index), 'repeated warning');
    Check(Filters.ShouldShow('bob', '', 'OMEMO', Index), 'separate contact');
    Check(Filters.ShouldShow('alice', 'other', 'OMEMO', Index), 'separate channel');
    Check(Filters.ShouldShow('alice', '', 'normal message', Index), 'normal messages survive');
    Check(not Filters.ShouldShow('alice', '', 'BUY NOW!', Index), 'ignore rule');
    Check(not Filters.ShouldShow('blocked@example.org', '', 'hello', Index), 'sender rule');
    Check(not Filters.ShouldShow('alice', 'muted-channel', 'hello', Index), 'channel rule');
    Check(Filters.ShouldShow('alice', 'not-muted', 'hello', Index), 'channel is exact');

    Config.WriteInteger('filter.omemo', 'cooldown_seconds', 1);
    Filters.Load(Config);
    Check(Filters.ShouldShow('alice', '', 'OMEMO', Index), 'reload clears seen state');
    Filters.MarkShown(Index, 'alice', '');
    Check(not Filters.ShouldShow('alice', '', 'OMEMO', Index), 'cooldown active');
    Sleep(1050);
    Check(Filters.ShouldShow('alice', '', 'OMEMO', Index), 'cooldown expired');

    Config.WriteString('filter.omemo', 'action', 'typo');
    Failed := False;
    try
      Filters.Load(Config);
    except
      on E: Exception do Failed := True;
    end;
    Check(Failed, 'invalid action must fail');
    Config.WriteString('filter.omemo', 'action', 'once_per_contact');
    Config.WriteInteger('filter.omemo', 'cooldown_seconds', 0);
    Config.WriteString('filter.omemo', 'body_contains', 'OMEMO encrypted');
    Filters.Load(Config);
    Check(Filters.ShouldShow('alice', '', 'This message is OMEMO encrypted', Index),
      'first actual warning');
    Filters.MarkShown(Index, 'alice', '');
    Check(not Filters.ShouldShow('alice', '',
      'I sent you an OMEMO encrypted message but your client doesn’t seem to support that.', Index),
      'both warning variants share contact history');
    Check(Filters.ShouldShow('bob', '',
      'I sent you an OMEMO encrypted message but your client doesn’t seem to support that.', Index),
      'second warning variant from another contact');
    Check(Filters.ShouldShow('alice', '', 'Let us discuss OMEMO', Index),
      'ordinary OMEMO discussion survives the narrower rule');
    Config.WriteString('filter.omemo', 'body_contains', 'OMEMO');
    Filters.Load(Config);
  finally
    Config.Free;
  end;
end;

procedure TestScanner(const Path: string);
var
  Scanner: TEventScanner;
  Watch: TDatabaseWatch;
  I, Before: Integer;
  Start: QWord;
  BodyText: string;
begin
  Check(sqlite3_open(PChar(Path), @Db) = SQLITE_OK, 'open fixture');
  try
    Exec('CREATE TABLE Events(id INTEGER PRIMARY KEY,remote_uid TEXT,channel TEXT,free_text TEXT,outgoing INTEGER)');
    Exec('CREATE TABLE remotes(remote_uid TEXT,remote_name TEXT)');
    Exec('INSERT INTO remotes VALUES(''alice'',''Shared display name'')');
    Exec('INSERT INTO remotes VALUES(''bob'',''Shared display name'')');
    Scanner := TEventScanner.Create(Path);
    Watch := TDatabaseWatch.Create(Path);
    try
      Check(Watch.Active >= 0, 'inotify available');
      Scanner.Initialize;
      Check(Scanner.Watermark = 0, 'empty database watermark');
      BodyText := 'hello' + #10 + 'գջվհգտի' + #31 + 'tail';
      AddEvent('alice', '', BodyText);
      Check(Scanner.Scan(@ReceiveEvent) = 1, 'first event from empty database');
      Check(LastBody = BodyText, 'UTF-8, newline, separator preservation');
      Check(LastContact = 'Shared display name', 'contact lookup');
      Check(Scanner.Scan(@ReceiveEvent) = 0, 'no replay');

      AddEvent('alice', '', 'OMEMO cannot decrypt');
      AddEvent('alice', '', 'OMEMO another warning');
      AddEvent('bob', '', 'OMEMO cannot decrypt');
      AddEvent('alice', '', 'BUY NOW');
      AddEvent('alice', '', 'outgoing message', 1);
      AddEvent('alice', '', '');
      Before := Delivered;
      Check(Scanner.Scan(@ReceiveEvent) = 6, 'filtered and outgoing advance watermark');
      Check(Delivered = Before + 2, 'once per stable contact, not display name');

      Online := False;
      AddEvent('alice', '', 'queued while offline');
      Before := Scanner.Watermark;
      Check(Scanner.Scan(@ReceiveEvent) = 0, 'offline scan preserves event');
      Check(Scanner.Watermark = Before, 'offline watermark preserved');
      Online := True;
      Check(Scanner.Scan(@ReceiveEvent) = 1, 'pending event delivered on reconnect');
      Check(LastBody = 'queued while offline', 'pending content');

      for I := 1 to 205 do AddEvent('alice', '', 'backlog');
      Check(Scanner.Scan(@ReceiveEvent) = EVENT_BATCH_SIZE, 'first backlog batch');
      Check(Scanner.Scan(@ReceiveEvent) = EVENT_BATCH_SIZE, 'second backlog batch');
      Check(Scanner.Scan(@ReceiveEvent) = 5, 'last backlog batch');

      // Drain earlier filesystem notifications, then check that reads do not wake us.
      Watch.Wait(10);
      Scanner.Scan(@ReceiveEvent);
      Start := GetTickCount64;
      Watch.Wait(150);
      Check(GetTickCount64 - Start >= 120, 'read scans must not trigger themselves');
      AddEvent('alice', '', 'new commit');
      Start := GetTickCount64;
      Watch.Wait(3000);
      Check(GetTickCount64 - Start < 1000, 'database write wakes promptly');
      Watch.Wake;
      Start := GetTickCount64;
      Watch.Wait(3000);
      Check(GetTickCount64 - Start < 1000, 'reconnect wakes promptly');

      Scanner.Free;
      Scanner := TEventScanner.Create(Path);
      Scanner.Initialize;
      Check(Scanner.Scan(@ReceiveEvent) = 0, 'restart skips existing history');
      Exec('PRAGMA journal_mode=WAL');
      Watch.Wait(10);
      AddEvent('alice', '', 'WAL commit');
      Start := GetTickCount64;
      Watch.Wait(3000);
      Check(GetTickCount64 - Start < 1000, 'WAL writes wake promptly');
      Check(Scanner.Scan(@ReceiveEvent) = 1, 'WAL message delivered');
      Exec('DROP TABLE remotes');
      AddEvent('unknown', '', 'no contact table');
      Check(Scanner.Scan(@ReceiveEvent) = 1, 'optional contact table');
      Check(LastContact = 'unknown', 'contact fallback');
    finally
      Watch.Free;
      Scanner.Free;
    end;
  finally
    sqlite3_close(Db);
  end;
end;

begin
  if ParamCount <> 1 then raise Exception.Create('Pass a new temporary database path');
  InitializeSqlite('libsqlite3.so.0');
  Filters := TNotificationFilters.Create;
  try
    TestFilters;
    TestScanner(ParamStr(1));
    WriteLn('Notification tests passed');
  finally
    Filters.Free;
    ReleaseSqlite;
  end;
end.
