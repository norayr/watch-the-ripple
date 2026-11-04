unit database_watch;

{$mode objfpc}{$H+}

interface

uses SysUtils, BaseUnix, Linux;

type
  TDatabaseWatch = class
  private
    FDirectory, FName: string;
    FFd, FWatch: Integer;
    FWake: TFilDes;
    procedure EnsureWatch;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    procedure Wake;
    procedure Wait(TimeoutMs: Integer);
    property Active: Integer read FWatch;
  end;

implementation

const
  FD_CLOSE_ON_EXEC = 1;

constructor TDatabaseWatch.Create(const Path: string);
begin
  inherited Create;
  FFd := -1;
  FWatch := -1;
  FWake[0] := -1;
  FWake[1] := -1;
  FDirectory := ExtractFileDir(ExpandFileName(Path));
  FName := ExtractFileName(Path);
  if fpPipe(FWake) <> 0 then raise Exception.Create('Cannot create scanner wake pipe');
  fpFcntl(FWake[0], F_SETFD, FD_CLOSE_ON_EXEC);
  fpFcntl(FWake[1], F_SETFD, FD_CLOSE_ON_EXEC);
  fpFcntl(FWake[0], F_SETFL, O_NONBLOCK);
  fpFcntl(FWake[1], F_SETFL, O_NONBLOCK);
  FFd := inotify_init;
  FWatch := -1;
  if FFd >= 0 then
  begin
    fpFcntl(FFd, F_SETFD, FD_CLOSE_ON_EXEC);
    fpFcntl(FFd, F_SETFL, O_NONBLOCK);
  end;
  EnsureWatch;
end;

destructor TDatabaseWatch.Destroy;
begin
  if FFd >= 0 then fpClose(FFd);
  if FWake[0] >= 0 then fpClose(FWake[0]);
  if FWake[1] >= 0 then fpClose(FWake[1]);
  inherited Destroy;
end;

procedure TDatabaseWatch.Wake;
var
  B: Byte;
begin
  B := 1;
  // A full nonblocking pipe already contains a pending wakeup.
  fpWrite(FWake[1], B, 1);
end;

procedure TDatabaseWatch.EnsureWatch;
begin
  if (FFd >= 0) and (FWatch < 0) then
    FWatch := inotify_add_watch(FFd, PChar(FDirectory),
      IN_MODIFY or IN_CLOSE_WRITE or IN_CREATE or IN_DELETE or
      IN_MOVED_TO or IN_MOVED_FROM or IN_DELETE_SELF or IN_MOVE_SELF);
end;

procedure TDatabaseWatch.Wait(TimeoutMs: Integer);
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
      FWatch := -1;
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
      FWatch := -1;
      Continue;
    end;
    Changed := False;
    // Coalesce a burst of journal/WAL events into one database scan.
    for Batch := 1 to 64 do
    begin
      N := fpRead(FFd, Buffer, SizeOf(Buffer));
      if N <= 0 then Break;
      Offset := 0;
      while Offset + 16 <= N do
      begin
        Event := Pinotify_event(@Buffer[Offset]);
        if Offset + 16 + Event^.len > N then Break;
        if (Event^.wd = FWatch) and
          (Event^.mask and (IN_IGNORED or IN_DELETE_SELF or IN_MOVE_SELF or IN_UNMOUNT) <> 0) then
        begin
          if FWatch >= 0 then inotify_rm_watch(FFd, FWatch);
          FWatch := -1;
          Changed := True;
        end;
        if Event^.mask and IN_Q_OVERFLOW <> 0 then Changed := True;
        if Event^.len > 0 then
        begin
          Name := PChar(@Event^.name);
          if (Name = FName) or (Name = FName + '-wal') or
            (Name = FName + '-journal') then Changed := True;
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
