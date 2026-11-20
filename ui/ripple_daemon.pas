unit ripple_daemon;

{$mode objfpc}{$H+}

interface

type
  TDaemonPause = class
  private
    FControl: string;
    FWasRunning: Boolean;
    function Run(const Command: string): Integer;
  public
    constructor Create(const Control: string = '');
    procedure Pause;
    procedure Resume;
  end;

implementation

uses Classes, SysUtils, Process;

constructor TDaemonPause.Create(const Control: string);
var Base: string;
begin
  inherited Create;
  if Control <> '' then
  begin
    FControl := Control;
    Exit;
  end;
  Base := ExtractFilePath(ExpandFileName(ParamStr(0)));
  FControl := Base + 'wtr';
  if not FileExists(FControl) then FControl := '/usr/bin/wtr';
  if not FileExists(FControl) then FControl := Base + 'scripts/wtr';
end;

function TDaemonPause.Run(const Command: string): Integer;
var P: TProcess;
begin
  P := TProcess.Create(nil);
  try
    P.Executable := FControl;
    P.Parameters.Add(Command);
    P.Options := [poWaitOnExit];
    P.Execute;
    Result := P.ExitStatus;
  finally P.Free; end;
end;

procedure TDaemonPause.Pause;
var Status, Attempt: Integer;
begin
  Status := Run('status');
  if (Status <> 0) and (Status <> 3) then
    raise Exception.Create('Cannot check wtrd; run Ripple as the desktop user');
  FWasRunning := Status = 0;
  if not FWasRunning then Exit;
  if Run('stop') <> 0 then
    raise Exception.Create('Cannot stop wtrd for watch access');
  for Attempt := 1 to 20 do
  begin
    Status := Run('status');
    if Status = 3 then Exit;
    if Status <> 0 then raise Exception.Create('Cannot confirm that wtrd has stopped');
    Sleep(100);
  end;
  raise Exception.Create('wtrd has not stopped; watch connection was not attempted');
end;

procedure TDaemonPause.Resume;
begin
  if not FWasRunning then Exit;
  if Run('start') <> 0 then
    raise Exception.Create('Could not restart wtrd; run wtr start and inspect wtr log');
  FWasRunning := False;
end;

end.
