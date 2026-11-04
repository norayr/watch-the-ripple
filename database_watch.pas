unit database_watch;

{$mode objfpc}{$H+}

interface

uses SysUtils, BaseUnix, Linux;

type
  TDirectoryWatch = class
  private
    type
      TWatchedDirectory = record
        Path: string;
        Handle: Integer;
      end;
    var
      FDirectories: array of TWatchedDirectory;
    FFd: Integer;
    FWake: TFilDes;
    procedure EnsureWatch;
    procedure InvalidateWatch(Handle: Integer);
    function GetActive: Integer;
  protected
    function RelevantName(const Name: string): Boolean; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddDirectory(const Path: string);
    procedure Wake;
    procedure Wait(TimeoutMs: Integer);
    property Active: Integer read GetActive;
  end;

  TDatabaseWatch = class(TDirectoryWatch)
  private
    FName: string;
  protected
    function RelevantName(const Name: string): Boolean; override;
  public
    constructor Create(const Path: string);
  end;

implementation

const
  FD_CLOSE_ON_EXEC = 1;

constructor TDirectoryWatch.Create;
begin
  inherited Create;
  FFd := -1;
  FWake[0] := -1;
  FWake[1] := -1;
  if fpPipe(FWake) <> 0 then raise Exception.Create('Cannot create scanner wake pipe');
  fpFcntl(FWake[0], F_SETFD, FD_CLOSE_ON_EXEC);
  fpFcntl(FWake[1], F_SETFD, FD_CLOSE_ON_EXEC);
  fpFcntl(FWake[0], F_SETFL, O_NONBLOCK);
  fpFcntl(FWake[1], F_SETFL, O_NONBLOCK);
  FFd := inotify_init;
  if FFd >= 0 then
  begin
    fpFcntl(FFd, F_SETFD, FD_CLOSE_ON_EXEC);
    fpFcntl(FFd, F_SETFL, O_NONBLOCK);
  end;
end;

destructor TDirectoryWatch.Destroy;
begin
  if FFd >= 0 then fpClose(FFd);
  if FWake[0] >= 0 then fpClose(FWake[0]);
  if FWake[1] >= 0 then fpClose(FWake[1]);
  inherited Destroy;
end;

procedure TDirectoryWatch.Wake;
var
  B: Byte;
begin
  B := 1;
  // A full nonblocking pipe already contains a pending wakeup.
  fpWrite(FWake[1], B, 1);
end;

procedure TDirectoryWatch.AddDirectory(const Path: string);
var
  I, N: Integer;
  FullPath: string;
begin
  FullPath := ExcludeTrailingPathDelimiter(ExpandFileName(Path));
  for I := 0 to High(FDirectories) do
    if FDirectories[I].Path = FullPath then Exit;
  N := Length(FDirectories);
  SetLength(FDirectories, N + 1);
  FDirectories[N].Path := FullPath;
  FDirectories[N].Handle := -1;
  EnsureWatch;
end;

procedure TDirectoryWatch.EnsureWatch;
var I: Integer;
begin
  if FFd < 0 then Exit;
  for I := 0 to High(FDirectories) do
    if FDirectories[I].Handle < 0 then
      FDirectories[I].Handle := inotify_add_watch(FFd, PChar(FDirectories[I].Path),
        IN_MODIFY or IN_CLOSE_WRITE or IN_CREATE or IN_DELETE or
        IN_MOVED_TO or IN_MOVED_FROM or IN_DELETE_SELF or IN_MOVE_SELF);
end;

procedure TDirectoryWatch.InvalidateWatch(Handle: Integer);
var I: Integer;
begin
  for I := 0 to High(FDirectories) do
    if (Handle < 0) or (FDirectories[I].Handle = Handle) then
    begin
      if (FFd >= 0) and (FDirectories[I].Handle >= 0) then
        inotify_rm_watch(FFd, FDirectories[I].Handle);
      FDirectories[I].Handle := -1;
    end;
end;

function TDirectoryWatch.GetActive: Integer;
var I: Integer;
begin
  Result := -1;
  for I := 0 to High(FDirectories) do
    if FDirectories[I].Handle >= 0 then Exit(FDirectories[I].Handle);
end;

function TDirectoryWatch.RelevantName(const Name: string): Boolean;
begin
  Result := True;
end;

constructor TDatabaseWatch.Create(const Path: string);
begin
  inherited Create;
  FName := ExtractFileName(Path);
  AddDirectory(ExtractFileDir(ExpandFileName(Path)));
end;

function TDatabaseWatch.RelevantName(const Name: string): Boolean;
begin
  Result := (Name = FName) or (Name = FName + '-wal') or
    (Name = FName + '-journal');
end;

procedure TDirectoryWatch.Wait(TimeoutMs: Integer);
var
  PollFds: array[0..1] of TPollFD;
  Buffer: array[0..8191] of Byte;
  N, Offset, Remaining, Batch: Integer;
  Event: Pinotify_event;
  Name: string;
  Deadline, NowMs: QWord;
  Changed: Boolean;
begin
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    EnsureWatch;
    NowMs := GetTickCount64;
    if NowMs >= Deadline then Exit;
    Remaining := Deadline - NowMs;
    FillChar(PollFds, SizeOf(PollFds), 0);
    PollFds[0].fd := FFd;
    PollFds[0].events := POLLIN;
    PollFds[1].fd := FWake[0];
    PollFds[1].events := POLLIN;
    N := fpPoll(@PollFds[0], 2, Remaining);
    if N = 0 then Exit;
    if N < 0 then
    begin
      if fpGetErrno = ESysEINTR then Continue;
      fpClose(FFd);
      FFd := -1;
      InvalidateWatch(-1);
      Sleep(Remaining);
      Exit;
    end;
    if PollFds[1].revents and POLLIN <> 0 then
    begin
      while fpRead(FWake[0], Buffer, SizeOf(Buffer)) > 0 do ;
      Exit;
    end;
    if PollFds[0].revents and (POLLERR or POLLHUP or POLLNVAL) <> 0 then
    begin
      fpClose(FFd);
      FFd := -1;
      InvalidateWatch(-1);
      Continue;
    end;
    Changed := False;
    // Coalesce a burst of filesystem events into one scan.
    for Batch := 1 to 64 do
    begin
      N := fpRead(FFd, Buffer, SizeOf(Buffer));
      if N <= 0 then Break;
      Offset := 0;
      while Offset + 16 <= N do
      begin
        Event := Pinotify_event(@Buffer[Offset]);
        if Offset + 16 + Event^.len > N then Break;
        if Event^.mask and (IN_IGNORED or IN_DELETE_SELF or IN_MOVE_SELF or IN_UNMOUNT) <> 0 then
        begin
          InvalidateWatch(Event^.wd);
          Changed := True;
        end;
        if Event^.mask and IN_Q_OVERFLOW <> 0 then Changed := True;
        if Event^.len > 0 then
        begin
          Name := PChar(@Event^.name);
          if RelevantName(Name) then Changed := True;
        end;
        Inc(Offset, 16 + Event^.len);
      end;
    end;
    if Changed then
    begin
      // Let a writer finish publishing its commit before reading the database.
      Sleep(50);
      Exit;
    end;
  until False;
end;

end.
