program control_daemon;

{$mode objfpc}{$H+}

uses SysUtils;

begin
  if FileExists(GetEnvironmentVariable('HOME') + '/fail-start') then Halt(1);
  while True do Sleep(1000);
end.
