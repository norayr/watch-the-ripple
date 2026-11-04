unit notification_filters;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, IniFiles;

type
  TNotificationFilters = class
  private
    type
      TSeenContact = record
        Key: string;
        ShownAt: QWord;
      end;
      TRule = record
        Name, ContainsText, Sender, Channel, Action: string;
        CooldownMs: QWord;
        Seen: array of TSeenContact;
      end;
    var
      FRules: array of TRule;
    function ContactKey(const Sender, Channel: string): string;
  public
    procedure Load(Config: TCustomIniFile);
    function ShouldShow(const ASender, AChannel, Body: string;
      out RuleIndex: Integer): Boolean;
    procedure MarkShown(RuleIndex: Integer; const Sender, Channel: string);
  end;

implementation

function TNotificationFilters.ContactKey(const Sender, Channel: string): string;
begin
  Result := IntToStr(Length(Sender)) + ':' + Sender + Channel;
end;

procedure TNotificationFilters.Load(Config: TCustomIniFile);
var
  Sections: TStringList;
  I, N: Integer;
  Seconds: Int64;
begin
  FRules := nil;
  Sections := TStringList.Create;
  try
    Config.ReadSections(Sections);
    for I := 0 to Sections.Count - 1 do
    begin
      if Copy(LowerCase(Sections[I]), 1, 7) <> 'filter.' then Continue;
      if not Config.ReadBool(Sections[I], 'enabled', True) then Continue;
      N := Length(FRules);
      SetLength(FRules, N + 1);
      with FRules[N] do
      begin
        Name := Sections[I];
        ContainsText := LowerCase(Config.ReadString(Name, 'body_contains', ''));
        Sender := Config.ReadString(Name, 'sender', '');
        Channel := Config.ReadString(Name, 'channel', '');
        Action := LowerCase(Trim(Config.ReadString(Name, 'action', 'ignore')));
        if (ContainsText = '') and (Sender = '') and (Channel = '') then
          raise Exception.Create(Name + ': specify body_contains, sender or channel');
        if (Action <> 'ignore') and (Action <> 'once_per_contact') then
          raise Exception.Create(Name + ': action must be ignore or once_per_contact');
        Seconds := Config.ReadInt64(Name, 'cooldown_seconds', 0);
        if (Seconds < 0) or (Seconds > High(Int64) div 1000) then
          raise Exception.Create(Name + ': invalid cooldown_seconds');
        CooldownMs := QWord(Seconds) * 1000;
      end;
    end;
  finally
    Sections.Free;
  end;
end;

function TNotificationFilters.ShouldShow(const ASender, AChannel, Body: string;
  out RuleIndex: Integer): Boolean;
var
  I, J: Integer;
  Key, FoldedBody: string;
begin
  RuleIndex := -1;
  Result := True;
  FoldedBody := LowerCase(Body);
  Key := ContactKey(ASender, AChannel);
  for I := 0 to High(FRules) do
    with FRules[I] do
    begin
      if (ContainsText <> '') and (Pos(ContainsText, FoldedBody) = 0) then Continue;
      if (Sender <> '') and (Sender <> ASender) then Continue;
      if (Channel <> '') and (Channel <> AChannel) then Continue;
      RuleIndex := I;
      if Action = 'ignore' then Exit(False);
      for J := 0 to High(Seen) do
        if Seen[J].Key = Key then
          Exit((CooldownMs > 0) and (GetTickCount64 - Seen[J].ShownAt >= CooldownMs));
      Exit(True);
    end;
end;

procedure TNotificationFilters.MarkShown(RuleIndex: Integer;
  const Sender, Channel: string);
var
  I, N: Integer;
  Key: string;
begin
  if RuleIndex < 0 then Exit;
  Key := ContactKey(Sender, Channel);
  with FRules[RuleIndex] do
  begin
    for I := 0 to High(Seen) do
      if Seen[I].Key = Key then
      begin
        Seen[I].ShownAt := GetTickCount64;
        Exit;
      end;
    N := Length(Seen);
    SetLength(Seen, N + 1);
    Seen[N].Key := Key;
    Seen[N].ShownAt := GetTickCount64;
  end;
end;

end.
