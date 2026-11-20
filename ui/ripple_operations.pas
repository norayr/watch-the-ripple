unit ripple_operations;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, SyncObjs, ripple_types;

type
  TRippleOperation = (roWatchfaces, roApps, roInstalled, roIdentify, roInstall, roRemove);
  TRippleWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FOperation: TRippleOperation;
    FItem: TRippleItem;
    FDone: Boolean;
    FText: string;
    FPercent: Integer;
    procedure Progress(const Text: string; Percent: Integer);
    procedure Registered(const Item: TRippleItem);
    procedure RunOperation;
  protected
    procedure Execute; override;
  public
    Items: TRippleItems;
    Info: TWatchInfo;
    ErrorText, Note: string;
    constructor Create(Operation: TRippleOperation; const Item: TRippleItem);
    destructor Destroy; override;
    procedure Snapshot(out Done: Boolean; out Text: string; out Percent: Integer);
  end;

implementation

uses ripple_catalog, ripple_settings, ripple_http, ripple_pbw,
  ripple_watch_link, ripple_watch_apps, ripple_daemon, ripple_watch_access, wtr_config;

constructor TRippleWorker.Create(Operation: TRippleOperation; const Item: TRippleItem);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FOperation := Operation;
  FItem := Item;
end;

destructor TRippleWorker.Destroy;
begin
  inherited Destroy;
  FLock.Free;
end;

procedure TRippleWorker.Progress(const Text: string; Percent: Integer);
begin
  FLock.Acquire;
  try FText := Text; FPercent := Percent;
  finally FLock.Release; end;
end;

procedure TRippleWorker.Snapshot(out Done: Boolean; out Text: string; out Percent: Integer);
begin
  FLock.Acquire;
  try Done := FDone; Text := FText; Percent := FPercent;
  finally FLock.Release; end;
end;

procedure TRippleWorker.Registered(const Item: TRippleItem);
begin
  SaveManagedApp(Info.Address, Item, False);
end;

procedure TRippleWorker.RunOperation;
var Address, Temp, LockPath: string; HTTP: TRippleHTTP; Stream: TFileStream;
  Link: TWatchLink; Daemon: TDaemonPause; PBW: TPBW; Banks: Cardinal;
  Access: TWatchAccess; Connector: TWatchConnector;
begin
  Address := '';
  if FOperation in [roWatchfaces, roApps] then
  begin
    try Address := WatchAddress; except end;
    Info := LoadWatchInfo(Address);
    Progress('Loading Rebble catalog', 0);
    Items := FetchCatalog(FOperation = roWatchfaces, Info.Platform);
    Note := 'Rebble featured catalog';
    if Info.Platform = '' then Note := Note + '; refresh Installed to detect watch hardware'
    else Note := Note + ' for ' + Info.Platform;
    Exit;
  end;
  Address := WatchAddress;
  LockPath := ExtractFilePath(ConfigFilePath);
  if not ForceDirectories(LockPath) then raise Exception.Create('Cannot create settings directory');
  Access := TWatchAccess.Create(LockPath + 'watch-access.lock');
  try
    Temp := '';
    try
      if FOperation = roInstall then
      begin
        if FItem.DownloadURL = '' then raise Exception.Create('No PBW download is available');
        Progress('Downloading PBW', 0);
        Temp := GetTempFileName;
        Stream := TFileStream.Create(Temp, fmOpenWrite);
        try
          HTTP := TRippleHTTP.Create;
          try HTTP.Get(FItem.DownloadURL, Stream, 32 * 1024 * 1024);
          finally HTTP.Free; end;
        finally Stream.Free; end;
      end;
      Daemon := TDaemonPause.Create;
      try
        try
          Progress('Connecting to watch; pausing notifications', 0);
          Daemon.Pause;
          Connector := TWatchConnector.Create;
          try Link := Connector.Connect(Address, @Progress);
          finally Connector.Free; end;
          try
            Info := Link.Identify;
            Info.Address := Address;
            SaveWatchInfo(Info);
            if Info.Major < 2 then raise Exception.Create('App management requires firmware 2 or later');
            case FOperation of
              roInstall:
                begin
                  PBW := TPBW.Create(Temp, Info.Platform);
                  try
                    if (FItem.UUID <> '') and (LowerCase(FItem.UUID) <> PBW.Item.UUID) then
                      raise Exception.Create('PBW UUID does not match the catalog entry');
                    InstallWatchApp(Link, PBW, Info.Major >= 3, @Progress, @Registered);
                    SaveManagedApp(Address, PBW.Item, False);
                    Note := 'Installed ' + PBW.Item.Title;
                  finally PBW.Free; end;
                end;
              roRemove:
                begin
                  RemoveWatchApp(Link, FItem, Info.Major >= 3);
                  SaveManagedApp(Address, FItem, True);
                  Note := 'Removed ' + FItem.Title;
                end;
              roIdentify: Note := Info.Platform + ' / ' + Info.Firmware;
            end;
            if FOperation in [roInstalled, roInstall, roRemove] then
              if Info.Major >= 3 then
              begin
                Items := LoadManagedApps(Address);
                if Note <> '' then Note := Note + '. ';
                Note := Note + 'Saved Ripple records only; firmware 3+ cannot report a live app inventory.';
              end
              else
              begin
                Items := ListWatchApps(Link, Banks);
                if Note <> '' then Note := Note + '. ';
                Note := Note + IntToStr(Length(Items)) + ' installed apps on watch';
              end;
          finally Link.Free; end;
        except
          on E: Exception do ErrorText := E.Message;
        end;
        Progress('Restoring notification daemon', 100);
        try Daemon.Resume;
        except
          on E: Exception do
            if ErrorText = '' then ErrorText := E.Message
            else ErrorText := ErrorText + LineEnding + E.Message;
        end;
      finally Daemon.Free; end;
    finally
      if Temp <> '' then DeleteFile(Temp);
    end;
  finally Access.Free; end;
end;

procedure TRippleWorker.Execute;
begin
  try
    try RunOperation;
    except on E: Exception do ErrorText := E.Message; end;
  finally
    FLock.Acquire;
    try FDone := True;
    finally FLock.Release; end;
  end;
end;

end.
