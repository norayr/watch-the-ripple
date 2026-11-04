unit mail_cache;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, database_watch;

const
  MAIL_BATCH_SIZE = 100;

type
  TMailEvent = record
    UID: Int64;
    Account, Sender, DisplaySender, Subject: string;
  end;
  TMailHandler = function(const Event: TMailEvent): Boolean;

  TMailCache = class
  private
    type
      TMailbox = record
        Path, Account: string;
        Baseline: Int64;
        Delivered: TStringList;
      end;
    var
      FRoot: string;
      FWatch: TDirectoryWatch;
      FMailboxes: array of TMailbox;
      FInitialized: Boolean;
    procedure Discover;
    procedure AddMailbox(const Path, Account: string);
    function GetMailboxCount: Integer;
  public
    constructor Create(const Root: string);
    destructor Destroy; override;
    procedure Initialize;
    function Scan(Handler: TMailHandler): Integer;
    procedure Wait(TimeoutMs: Integer);
    procedure Wake;
    property Watch: TDirectoryWatch read FWatch;
    property MailboxCount: Integer read GetMailboxCount;
  end;

function ReadMailHeaders(const Path, Account: string; out Event: TMailEvent): Boolean;

implementation

uses StrUtils, base64;

function MessageUID(const Name: string; out UID: Int64): Boolean;
var I: Integer;
begin
  Result := False;
  if (Length(Name) < 3) or (Copy(Name, Length(Name) - 1, 2) <> '.~') then Exit;
  for I := 1 to Length(Name) - 2 do
    if not (Name[I] in ['0'..'9']) then Exit;
  Result := TryStrToInt64(Copy(Name, 1, Length(Name) - 2), UID) and (UID > 0);
end;

function DecodeWord(const Word: string; out Decoded: string): Boolean;
var
  Charset, Data: string;
  Encoding: Char;
  P, I, V: Integer;
  U: UnicodeString;
begin
  Result := False;
  P := PosEx('?', Word, 3);
  if (P = 0) or (P + 2 >= Length(Word)) or (Word[P + 2] <> '?') then Exit;
  Charset := LowerCase(Copy(Word, 3, P - 3));
  Encoding := UpCase(Word[P + 1]);
  Data := Copy(Word, P + 3, Length(Word) - P - 4);
  if Encoding = 'B' then
  begin
    try
      Decoded := DecodeStringBase64(Data, True);
    except
      Exit;
    end;
  end
  else if Encoding = 'Q' then
  begin
    Decoded := '';
    I := 1;
    while I <= Length(Data) do
    begin
      case Data[I] of
        '_': Decoded := Decoded + ' ';
        '=':
          begin
            if (I + 2 > Length(Data)) or
              not (Data[I + 1] in ['0'..'9', 'A'..'F', 'a'..'f']) or
              not (Data[I + 2] in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit;
            if not TryStrToInt('$' + Copy(Data, I + 1, 2), V) then Exit;
            Decoded := Decoded + Chr(V);
            Inc(I, 2);
          end;
        else Decoded := Decoded + Data[I];
      end;
      Inc(I);
    end;
  end
  else Exit;

  if (Charset = 'iso-8859-1') or (Charset = 'latin1') then
  begin
    SetLength(U, Length(Decoded));
    for I := 1 to Length(Decoded) do U[I] := WideChar(Byte(Decoded[I]));
    Decoded := UTF8Encode(U);
  end
  else if (Charset <> 'utf-8') and (Charset <> 'utf8') and (Charset <> 'us-ascii') then
    Exit;
  Result := True;
end;

function DecodeHeader(const Header: string): string;
var
  I, Start, Finish, Separator: Integer;
  Prefix, Decoded: string;
  PreviousWord: Boolean;
begin
  Result := '';
  I := 1;
  PreviousWord := False;
  while I <= Length(Header) do
  begin
    Start := PosEx('=?', Header, I);
    if Start = 0 then Break;
    Separator := PosEx('?', Header, Start + 2);
    if (Separator = 0) or (Separator + 2 >= Length(Header)) or
      (Header[Separator + 2] <> '?') then Break;
    Finish := PosEx('?=', Header, Separator + 3);
    if Finish = 0 then Break;
    Prefix := Copy(Header, I, Start - I);
    if DecodeWord(Copy(Header, Start, Finish + 2 - Start), Decoded) then
    begin
      if not PreviousWord or (Trim(Prefix) <> '') then Result := Result + Prefix;
      Result := Result + Decoded;
      PreviousWord := True;
    end
    else
    begin
      Result := Result + Prefix + Copy(Header, Start, Finish + 2 - Start);
      PreviousWord := False;
    end;
    I := Finish + 2;
  end;
  Result := Result + Copy(Header, I, MaxInt);
end;

function ReadMailHeaders(const Path, Account: string; out Event: TMailEvent): Boolean;
const
  MAX_HEADERS = 65536;
var
  Stream: TFileStream;
  Raw, Name, Value, FromValue, SubjectValue, Line: string;
  Lines: TStringList;
  N, I, P, Q: Integer;

  procedure FinishHeader;
  begin
    if (Name = 'from') and (FromValue = '') then FromValue := DecodeHeader(Trim(Value));
    if (Name = 'subject') and (SubjectValue = '') then SubjectValue := DecodeHeader(Trim(Value));
  end;

begin
  Result := False;
  Event := Default(TMailEvent);
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      N := MAX_HEADERS;
      if Stream.Size < N then N := Stream.Size;
      SetLength(Raw, N);
      if N > 0 then Stream.ReadBuffer(Raw[1], N);
    finally
      Stream.Free;
    end;
  except
    on E: EStreamError do Exit;
    on E: EOSError do Exit;
  end;
  Raw := StringReplace(Raw, #13#10, #10, [rfReplaceAll]);
  P := Pos(#10#10, Raw);
  if P = 0 then Exit; // A partially written header is retried after the next change.
  Lines := TStringList.Create;
  try
    Lines.Text := Copy(Raw, 1, P - 1);
    Name := '';
    Value := '';
    FromValue := '';
    SubjectValue := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Line <> '') and (Line[1] in [' ', #9]) then
        Value := Value + ' ' + Trim(Line)
      else
      begin
        FinishHeader;
        P := Pos(':', Line);
        Name := LowerCase(Copy(Line, 1, P - 1));
        if P > 0 then Value := Trim(Copy(Line, P + 1, MaxInt)) else Value := '';
      end;
    end;
    FinishHeader;
  finally
    Lines.Free;
  end;
  Event.Account := Account;
  Event.DisplaySender := FromValue;
  if Event.DisplaySender = '' then Event.DisplaySender := Account;
  Event.Sender := Event.DisplaySender;
  P := Pos('<', FromValue);
  Q := PosEx('>', FromValue, P + 1);
  if (P > 0) and (Q > P) then Event.Sender := Trim(Copy(FromValue, P + 1, Q - P - 1));
  Event.Subject := SubjectValue;
  if Event.Subject = '' then Event.Subject := 'New email';
  Result := True;
end;

constructor TMailCache.Create(const Root: string);
begin
  inherited Create;
  FRoot := IncludeTrailingPathDelimiter(ExpandFileName(Root));
  FWatch := TDirectoryWatch.Create;
  FWatch.AddDirectory(FRoot);
end;

destructor TMailCache.Destroy;
var I: Integer;
begin
  FWatch.Free;
  for I := 0 to High(FMailboxes) do FMailboxes[I].Delivered.Free;
  inherited Destroy;
end;

procedure TMailCache.AddMailbox(const Path, Account: string);
var
  I, N: Integer;
  Search: TSearchRec;
  UID: Int64;
begin
  for I := 0 to High(FMailboxes) do
    if FMailboxes[I].Path = Path then Exit;
  FWatch.AddDirectory(Path);
  N := Length(FMailboxes);
  SetLength(FMailboxes, N + 1);
  FMailboxes[N].Path := IncludeTrailingPathDelimiter(Path);
  FMailboxes[N].Account := Account;
  FMailboxes[N].Delivered := TStringList.Create;
  FMailboxes[N].Delivered.Sorted := True;
  // Snapshot existing cache UIDs so startup and account discovery do not replay history.
  if FindFirst(FMailboxes[N].Path + '*.~', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Attr and faDirectory = 0) and MessageUID(Search.Name, UID) then
        if UID > FMailboxes[N].Baseline then FMailboxes[N].Baseline := UID;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure TMailCache.Discover;
var
  Accounts, Folders: TSearchRec;
  AccountPath, FolderPath: string;
begin
  if FindFirst(FRoot + '*', faDirectory, Accounts) <> 0 then Exit;
  try
    repeat
      if (Accounts.Attr and faDirectory = 0) or (Accounts.Name = '.') or
        (Accounts.Name = '..') then Continue;
      AccountPath := FRoot + Accounts.Name;
      FWatch.AddDirectory(AccountPath);
      FolderPath := AccountPath + '/folders/';
      FWatch.AddDirectory(FolderPath);
      if FindFirst(FolderPath + '*', faDirectory, Folders) <> 0 then Continue;
      try
        repeat
          if (Folders.Attr and faDirectory <> 0) and SameText(Folders.Name, 'INBOX') then
            AddMailbox(IncludeTrailingPathDelimiter(FolderPath + Folders.Name), Accounts.Name);
        until FindNext(Folders) <> 0;
      finally
        FindClose(Folders);
      end;
    until FindNext(Accounts) <> 0;
  finally
    FindClose(Accounts);
  end;
end;

procedure TMailCache.Initialize;
begin
  if FInitialized then Exit;
  Discover;
  FInitialized := True;
end;

function TMailCache.GetMailboxCount: Integer;
begin
  Result := Length(FMailboxes);
end;

function TMailCache.Scan(Handler: TMailHandler): Integer;
type
  TCandidate = record
    UID: Int64;
    Name: string;
  end;
var
  Candidates: array of TCandidate;
  Candidate: TCandidate;
  Search: TSearchRec;
  Event: TMailEvent;
  UID: Int64;
  Box, I, J, N: Integer;
begin
  Result := 0;
  Initialize;
  Discover;
  for Box := 0 to High(FMailboxes) do
  begin
    Candidates := nil;
    with FMailboxes[Box] do
    begin
      if FindFirst(Path + '*.~', faAnyFile, Search) <> 0 then Continue;
      try
        repeat
          if (Search.Attr and faDirectory <> 0) or not MessageUID(Search.Name, UID) then Continue;
          if (UID <= Baseline) or (Delivered.IndexOf(IntToStr(UID)) >= 0) then Continue;
          N := Length(Candidates);
          SetLength(Candidates, N + 1);
          Candidates[N].UID := UID;
          Candidates[N].Name := Search.Name;
        until FindNext(Search) <> 0;
      finally
        FindClose(Search);
      end;
      // Cache files can arrive out of order; sort each batch without losing lower UIDs.
      for I := 1 to High(Candidates) do
      begin
        Candidate := Candidates[I];
        J := I - 1;
        while (J >= 0) and (Candidates[J].UID > Candidate.UID) do
        begin
          Candidates[J + 1] := Candidates[J];
          Dec(J);
        end;
        Candidates[J + 1] := Candidate;
      end;
      for I := 0 to High(Candidates) do
      begin
        if not ReadMailHeaders(Path + Candidates[I].Name, Account, Event) then Continue;
        Event.UID := Candidates[I].UID;
        if not Handler(Event) then Exit;
        Delivered.Add(IntToStr(Event.UID));
        Inc(Result);
        if Result = MAIL_BATCH_SIZE then Exit;
      end;
    end;
  end;
end;

procedure TMailCache.Wait(TimeoutMs: Integer);
begin
  FWatch.Wait(TimeoutMs);
end;

procedure TMailCache.Wake;
begin
  FWatch.Wake;
end;

end.
