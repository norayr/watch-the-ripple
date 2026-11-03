program maebbled;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  Classes,
  maebble in 'maebble.pas';

//{$R *.res}

begin
  Main;
end.
