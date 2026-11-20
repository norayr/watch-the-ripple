unit ripple_settings;

{$mode objfpc}{$H+}

interface

uses ripple_types;

function WatchAddress: string;
function LoadWatchInfo(const Address: string): TWatchInfo;
procedure SaveWatchInfo(const Info: TWatchInfo);
function LoadManagedApps(const Address: string): TRippleItems;
procedure SaveManagedApp(const Address: string; const Item: TRippleItem; Remove: Boolean);

implementation

uses Classes, SysUtils, IniFiles, wtr_config, ripple_bytes;

function SettingsPath: string;
begin
  Result := ExtractFilePath(ConfigFilePath) + 'ripple.ini';
end;

function AppPath(const Address: string): string;
var I: Integer;
begin
  Result := '';
  for I := 1 to Length(Address) do
    if Address[I] in ['0'..'9', 'a'..'f', 'A'..'F'] then Result := Result + Address[I];
  if Length(Result) <> 12 then raise Exception.Create('Invalid watch address');
  Result := ExtractFilePath(ConfigFilePath) + 'apps-' + LowerCase(Result) + '.ini';
end;

function WatchAddress: string;
var Ini: TIniFile; Filename: string;
begin
  Filename := FindConfigFile;
  if Filename = '' then raise Exception.Create('Run wtr init and set the watch address');
  Ini := TIniFile.Create(Filename);
  try Result := UpperCase(Trim(Ini.ReadString('btservice', 'address', '')));
  finally Ini.Free; end;
  if Result = '' then raise Exception.Create('Set [btservice] address in ' + Filename);
end;

function LoadWatchInfo(const Address: string): TWatchInfo;
var Ini: TIniFile;
begin
  Result := Default(TWatchInfo);
  Result.Address := Address;
  Ini := TIniFile.Create(SettingsPath);
  try
    if Ini.ReadString('watch', 'address', '') <> Address then Exit;
    Result.Firmware := Ini.ReadString('watch', 'firmware', '');
    Result.Platform := Ini.ReadString('watch', 'platform', '');
    Result.Major := Ini.ReadInteger('watch', 'major', 0);
    if (Result.Platform <> 'aplite') and (Result.Platform <> 'basalt') and
      (Result.Platform <> 'chalk') and (Result.Platform <> 'diorite') and
      (Result.Platform <> 'emery') and (Result.Platform <> 'flint') and
      (Result.Platform <> 'gabbro') then Result.Platform := '';
  finally Ini.Free; end;
end;

procedure SaveWatchInfo(const Info: TWatchInfo);
var Ini: TIniFile;
begin
  if not ForceDirectories(ExtractFilePath(SettingsPath)) then
    raise Exception.Create('Cannot create Ripple settings directory');
  Ini := TIniFile.Create(SettingsPath);
  try
    Ini.WriteString('watch', 'address', Info.Address);
    Ini.WriteString('watch', 'firmware', Info.Firmware);
    Ini.WriteString('watch', 'platform', Info.Platform);
    Ini.WriteInteger('watch', 'major', Info.Major);
  finally Ini.Free; end;
end;

function LoadManagedApps(const Address: string): TRippleItems;
var Ini: TIniFile; Sections: TStringList; I: Integer;
begin
  Result := nil;
  Ini := TIniFile.Create(AppPath(Address));
  Sections := TStringList.Create;
  try
    Ini.ReadSections(Sections);
    SetLength(Result, Sections.Count);
    for I := 0 to Sections.Count - 1 do
    begin
      UUIDBytes(Sections[I]);
      Result[I].UUID := Sections[I];
      Result[I].Title := Ini.ReadString(Sections[I], 'title', Sections[I]);
      Result[I].Author := Ini.ReadString(Sections[I], 'author', '');
      Result[I].Version := Ini.ReadString(Sections[I], 'version', '');
      Result[I].Description := 'Saved Ripple app registration; watch inventory unavailable on firmware 3+. A failed transfer can leave a registration without its binary.';
    end;
  finally Sections.Free; Ini.Free; end;
end;

procedure SaveManagedApp(const Address: string; const Item: TRippleItem; Remove: Boolean);
var Ini: TIniFile; Path: string;
begin
  UUIDBytes(Item.UUID);
  Path := AppPath(Address);
  if not ForceDirectories(ExtractFilePath(Path)) then
    raise Exception.Create('Cannot create Ripple settings directory');
  Ini := TIniFile.Create(Path);
  try
    if Remove then Ini.EraseSection(Item.UUID)
    else
    begin
      Ini.WriteString(Item.UUID, 'title', Item.Title);
      Ini.WriteString(Item.UUID, 'author', Item.Author);
      Ini.WriteString(Item.UUID, 'version', Item.Version);
    end;
  finally Ini.Free; end;
end;

end.
