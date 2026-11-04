unit wtr_config;

{$mode objfpc}{$H+}

interface

function ConfigFilePath: string;
function LegacyConfigFilePath: string;
function FindConfigFile: string;

implementation

uses SysUtils;

function HomeDirectory: string;
begin
  Result := GetEnvironmentVariable('HOME');
  if Result = '' then Result := '/home/user';
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function ConfigFilePath: string;
var Root: string;
begin
  Root := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Root = '' then Root := HomeDirectory + '/.config';
  Result := IncludeTrailingPathDelimiter(Root) + 'wtr/wtr.conf';
end;

function LegacyConfigFilePath: string;
begin
  Result := HomeDirectory + '/.config/maebble/maebble.cfg';
end;

function FindConfigFile: string;
begin
  if FileExists(ConfigFilePath) then Exit(ConfigFilePath);
  // Preserve a user's existing settings ahead of the empty local example.
  if FileExists(LegacyConfigFilePath) then Exit(LegacyConfigFilePath);
  if FileExists('wtr.conf') then Exit('wtr.conf');
  if FileExists('maebble.cfg') then Exit('maebble.cfg');
  Result := '';
end;

end.
