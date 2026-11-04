program test_wtr_config;

{$mode objfpc}{$H+}

uses SysUtils, Classes, wtr_config;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then raise Exception.Create(Msg);
end;

procedure Touch(const Path: string);
var Stream: TFileStream;
begin
  if ExtractFileDir(Path) <> '' then ForceDirectories(ExtractFileDir(Path));
  Stream := TFileStream.Create(Path, fmCreate);
  Stream.Free;
end;

var
  Root, ExpectedPath, OldPath: string;
begin
  if ParamCount <> 1 then raise Exception.Create('Pass a temporary fixture directory');
  Root := ParamStr(1);
  Check(GetEnvironmentVariable('HOME') = Root + '/home', 'use an isolated test HOME');
  if GetEnvironmentVariable('XDG_CONFIG_HOME') = '' then
    ExpectedPath := Root + '/home/.config/wtr/wtr.conf'
  else
    ExpectedPath := Root + '/xdg/wtr/wtr.conf';
  OldPath := Root + '/home/.config/maebble/maebble.cfg';
  Check(ConfigFilePath = ExpectedPath, 'new user configuration path');
  Check(LegacyConfigFilePath = OldPath, 'legacy user configuration path');
  Check(FindConfigFile = '', 'no configuration found');

  Touch('maebble.cfg');
  Check(FindConfigFile = 'maebble.cfg', 'legacy local fallback');
  Touch('wtr.conf');
  Check(FindConfigFile = 'wtr.conf', 'new local file preferred over legacy local file');
  Touch(OldPath);
  Check(FindConfigFile = OldPath, 'legacy personal config preferred over local example');
  Touch(ExpectedPath);
  Check(FindConfigFile = ExpectedPath, 'new personal configuration takes precedence');

  DeleteFile(ExpectedPath);
  Check(FindConfigFile = OldPath, 'legacy personal fallback after removing new file');
  DeleteFile(OldPath);
  Check(FindConfigFile = 'wtr.conf', 'new local fallback');
  DeleteFile('wtr.conf');
  Check(FindConfigFile = 'maebble.cfg', 'legacy local fallback after removing new file');
  DeleteFile('maebble.cfg');
  Check(FindConfigFile = '', 'no stale configuration path');
  WriteLn('Configuration path tests passed');
end.
