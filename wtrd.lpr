program wtrd;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  Classes,
  wtr in 'wtr.pas';

//{$R *.res}

begin
  Main;
end.
