program test_mail_cache;

{$mode objfpc}{$H+}{$codepage utf8}

uses
  cthreads, SysUtils, Classes, base64, mail_cache, database_watch;

var
  Delivered: TStringList;
  Online: Boolean = True;
  LastEvent: TMailEvent;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then raise Exception.Create(Msg);
end;

procedure WriteFile(const Path, Text: string);
var Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(Path));
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Text <> '' then Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
end;

function ReceiveMail(const Event: TMailEvent): Boolean;
begin
  Result := Online;
  if not Online then Exit;
  LastEvent := Event;
  Delivered.Add(Event.Account + '/' + IntToStr(Event.UID));
end;

procedure TestHeaders(const Root: string);
var
  Event: TMailEvent;
  Path, Armenian, Expected: string;
begin
  Path := Root + '/header-test';
  WriteFile(Path, 'From: Alice <alice@example.org>' + #13#10 +
    'Subject: A folded' + #13#10 + #9 + 'subject' + #13#10#13#10 + 'body');
  Check(ReadMailHeaders(Path, 'account', Event), 'plain MIME headers');
  Check(Event.Sender = 'alice@example.org', 'stable sender address');
  Check(Event.DisplaySender = 'Alice <alice@example.org>', 'display sender');
  Check(Event.Subject = 'A folded subject', 'folded header');

  Armenian := 'նորայր';
  WriteFile(Path, 'From: =?UTF-8?B?' + EncodeStringBase64(Armenian) +
    '?= <alice@example.org>' + #10 + 'Subject: =?UTF-8?B?' +
    EncodeStringBase64('Hello ') + '?= ' + #10 + #9 + '=?UTF-8?B?' +
    EncodeStringBase64(Armenian) + '?=' + #10#10 + StringOfChar('x', 70000));
  Check(ReadMailHeaders(Path, 'account', Event), 'base64 MIME headers and large body');
  Expected := Armenian + ' <alice@example.org>';
  Check(Event.DisplaySender = Expected, 'Armenian sender');
  Expected := 'Hello ' + Armenian;
  Check(Event.Subject = Expected, 'adjacent encoded words');

  WriteFile(Path, 'From: alice@example.org' + #10 +
    'Subject: =?UTF-8?Q?=D5=B6=D5=B8=D6=80=D5=A1=D5=B5=D6=80?=' + #10#10);
  Check(ReadMailHeaders(Path, 'account', Event), 'Q encoding starting with an escape');
  Check(Event.Subject = Armenian, 'Q-encoded Armenian subject');
  WriteFile(Path, 'Subject: =?ISO-8859-1?Q?caf=E9?=' + #10#10);
  Check(ReadMailHeaders(Path, 'account', Event), 'Latin-1 encoded word');
  Expected := 'café';
  Check(Event.Subject = Expected, 'Latin-1 converted to UTF-8');

  WriteFile(Path, 'Subject: =?UNKNOWN?Q?literal?=' + #10#10);
  Check(ReadMailHeaders(Path, 'account', Event), 'unknown charset');
  Check(Event.Subject = '=?UNKNOWN?Q?literal?=', 'unknown charset preserved');
  WriteFile(Path, 'Subject: =?UTF-8?Q?bad=ZZ?=' + #10#10);
  Check(ReadMailHeaders(Path, 'account', Event), 'malformed encoding');
  Check(Event.Subject = '=?UTF-8?Q?bad=ZZ?=', 'malformed word preserved');
  WriteFile(Path, 'Subject: =?UTF-8?B?!!!!?=' + #10#10);
  Check(ReadMailHeaders(Path, 'account', Event), 'malformed base64 does not abort scan');
  WriteFile(Path, 'From: alice@example.org' + #10 + 'Subject: unfinished');
  Check(not ReadMailHeaders(Path, 'account', Event), 'partial headers deferred');
  Check(not ReadMailHeaders(Root + '/missing', 'account', Event), 'missing file deferred');
  WriteFile(Path, 'Date: Wed, 4 Nov 2026 18:34:00 +0400' + #10#10);
  Check(ReadMailHeaders(Path, 'account', Event), 'missing optional headers');
  Check((Event.Sender = 'account') and (Event.Subject = 'New email'), 'generic fallback');
end;

procedure TestCache(const Root: string);
const
  Message = 'From: Alice <alice@example.org>' + #13#10 +
    'Subject: Test email' + #13#10#13#10 + 'body';
var
  Cache: TMailCache;
  Inbox, OtherInbox: string;
  Start: QWord;
  I: Integer;
begin
  Inbox := Root + '/alice__example.org_143/folders/INBOX/';
  OtherInbox := Root + '/second-account/folders/inbox/';
  WriteFile(Inbox + '37918.~', Message);
  WriteFile(OtherInbox + '1.~', Message);
  Cache := TMailCache.Create(Root);
  try
    Cache.Initialize;
    Check(Cache.MailboxCount = 2, 'both accounts discovered');
    Check(Cache.Watch.Active >= 0, 'cache inotify watch');
    Check(Cache.Scan(@ReceiveMail) = 0, 'existing cached history skipped');
    WriteFile(Inbox + 'highestmodseq', '999999999');
    WriteFile(Inbox + 'summary.mmap', 'metadata refresh');
    WriteFile(Inbox + '37918.~', Message);
    WriteFile(Inbox + '37917.~', Message);
    WriteFile(Root + '/alice__example.org_143/folders/Sent/99999.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 0, 'metadata, rewrites, old UIDs and Sent ignored');

    WriteFile(Inbox + '37920.~', Message);
    WriteFile(Inbox + '37919.~', Message);
    Start := GetTickCount64;
    Cache.Wait(3000);
    Check(GetTickCount64 - Start < 1000, 'new cache files wake promptly');
    Check(Cache.Scan(@ReceiveMail) = 2, 'new emails detected');
    Check(Delivered[0] = 'alice__example.org_143/37919', 'numeric UID order');
    Check(Delivered[1] = 'alice__example.org_143/37920', 'next UID');
    Check(LastEvent.Subject = 'Test email', 'subject supplied to notification callback');
    Check(Cache.Scan(@ReceiveMail) = 0, 'duplicate folder signals do not replay mail');
    WriteFile(Inbox + '37919.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 0, 'rewriting a delivered message does not replay it');
    DeleteFile(Inbox + '37919.~');
    WriteFile(Inbox + '37919.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 0, 'recaching a delivered UID does not replay it');

    WriteFile(Inbox + '37922.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 1, 'higher UID first');
    WriteFile(Inbox + '37921.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 1, 'lower new UID arriving later is retained');
    WriteFile(OtherInbox + '37921.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 1, 'same UID in another account is independent');
    Check(LastEvent.Account = 'second-account', 'lowercase inbox detected');

    Online := False;
    WriteFile(Inbox + '37923.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 0, 'failed notification retained');
    Online := True;
    Cache.Wake;
    Start := GetTickCount64;
    Cache.Wait(3000);
    Check(GetTickCount64 - Start < 1000, 'reconnect wakes email scanner');
    Check(Cache.Scan(@ReceiveMail) = 1, 'pending email delivered after reconnect');
    WriteFile(Inbox + '37924.~', 'From: alice@example.org' + #10 + 'Subject: partial');
    Check(Cache.Scan(@ReceiveMail) = 0, 'partial cache write deferred');
    WriteFile(Inbox + '37924.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 1, 'completed cache write delivered');

    for I := 1 to 205 do WriteFile(Inbox + IntToStr(38000 + I) + '.~', Message);
    Check(Cache.Scan(@ReceiveMail) = MAIL_BATCH_SIZE, 'first email backlog batch');
    Check(Cache.Scan(@ReceiveMail) = MAIL_BATCH_SIZE, 'second email backlog batch');
    Check(Cache.Scan(@ReceiveMail) = 5, 'last email backlog batch');
    Cache.Wait(10);
    Check(Cache.Scan(@ReceiveMail) = 0, 'read scan at idle');
    Start := GetTickCount64;
    Cache.Wait(150);
    Check(GetTickCount64 - Start >= 120, 'cache reads must not wake their own scanner');

    OtherInbox := Root + '/new-account/folders/INBOX/';
    WriteFile(OtherInbox + '50.~', Message);
    Check(Cache.Scan(@ReceiveMail) = 0, 'newly discovered account gets a history baseline');
    WriteFile(OtherInbox + '51.~', Message);
    Cache.Wait(3000);
    Check(Cache.Scan(@ReceiveMail) = 1, 'new account is watched');
  finally
    Cache.Free;
  end;
  Cache := TMailCache.Create(Root);
  try
    Cache.Initialize;
    Check(Cache.Scan(@ReceiveMail) = 0, 'restart does not replay cached mail');
  finally
    Cache.Free;
  end;
end;

procedure TestMissingRoot(const Root: string);
var Cache: TMailCache;
begin
  Cache := TMailCache.Create(Root);
  try
    Cache.Initialize;
    Check(Cache.Scan(@ReceiveMail) = 0, 'missing cache is harmless');
    WriteFile(Root + '/account/folders/INBOX/1.~', 'Subject: history' + #10#10);
    Check(Cache.Scan(@ReceiveMail) = 0, 'cache appearing later is baselined');
    WriteFile(Root + '/account/folders/INBOX/2.~', 'Subject: new email' + #10#10);
    Check(Cache.Scan(@ReceiveMail) = 1, 'mail after missing cache recovery');
  finally
    Cache.Free;
  end;
end;

begin
  if ParamCount <> 1 then raise Exception.Create('Pass a temporary directory path');
  Delivered := TStringList.Create;
  try
    TestHeaders(ParamStr(1));
    TestCache(ParamStr(1) + '/imap');
    TestMissingRoot(ParamStr(1) + '/initially-missing');
    WriteLn('Email cache tests passed');
  finally
    Delivered.Free;
  end;
end.
