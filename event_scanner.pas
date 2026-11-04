unit event_scanner;

{$mode objfpc}{$H+}

interface

uses SysUtils, sqlite3dyn;

const
  EVENT_BATCH_SIZE = 100;

type
  TMessageEvent = record
    Id: Int64;
    Sender, Channel, Body, Contact: string;
    Outgoing: Boolean;
  end;
  TMessageHandler = function(const Event: TMessageEvent): Boolean;

  TEventScanner = class
  private
    FPath: string;
    FWatermark: Int64;
    FInitialized: Boolean;
    function OpenDb: psqlite3;
  public
    constructor Create(const Path: string);
    destructor Destroy; override;
    procedure Initialize;
    function Scan(Handler: TMessageHandler): Integer;
    property Watermark: Int64 read FWatermark;
  end;

implementation

function ColumnText(Stmt: psqlite3_stmt; Col: Integer): string;
begin
  SetString(Result, sqlite3_column_text(Stmt, Col), sqlite3_column_bytes(Stmt, Col));
end;

constructor TEventScanner.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  InitializeSqlite('libsqlite3.so.0');
end;

destructor TEventScanner.Destroy;
begin
  ReleaseSqlite;
  inherited Destroy;
end;

function TEventScanner.OpenDb: psqlite3;
var
  Code: Integer;
  Msg: string;
begin
  Result := nil;
  Code := sqlite3_open_v2(PChar(FPath), @Result, SQLITE_OPEN_READONLY, nil);
  if Code <> SQLITE_OK then
  begin
    Msg := 'Cannot open event database: ' + string(sqlite3_errmsg(Result));
    sqlite3_close(Result);
    raise Exception.Create(Msg);
  end;
  sqlite3_busy_timeout(Result, 1000);
end;

procedure TEventScanner.Initialize;
var
  Db: psqlite3;
  Stmt: psqlite3_stmt;
begin
  if FInitialized then Exit;
  if not FileExists(FPath) then
  begin
    FInitialized := True;
    Exit;
  end;
  Db := OpenDb;
  Stmt := nil;
  try
    if sqlite3_prepare_v2(Db, 'SELECT COALESCE(MAX(id),0) FROM Events', -1,
      @Stmt, nil) <> SQLITE_OK then
      raise Exception.Create(string(sqlite3_errmsg(Db)));
    if sqlite3_step(Stmt) <> SQLITE_ROW then
      raise Exception.Create(string(sqlite3_errmsg(Db)));
    FWatermark := sqlite3_column_int64(Stmt, 0);
    FInitialized := True;
  finally
    sqlite3_finalize(Stmt);
    sqlite3_close(Db);
  end;
end;

function TEventScanner.Scan(Handler: TMessageHandler): Integer;
const
  SQL = 'SELECT id, remote_uid, channel, free_text, COALESCE(outgoing,0) ' +
    'FROM Events WHERE id > ? ORDER BY id LIMIT 100';
var
  Db: psqlite3;
  Stmt, ContactStmt: psqlite3_stmt;
  Events: array[0..EVENT_BATCH_SIZE - 1] of TMessageEvent;
  Count, Code, I: Integer;
begin
  Result := 0;
  Initialize;
  if not FileExists(FPath) then Exit;
  Db := OpenDb;
  Stmt := nil;
  ContactStmt := nil;
  Count := 0;
  try
    if sqlite3_prepare_v2(Db, SQL, -1, @Stmt, nil) <> SQLITE_OK then
      raise Exception.Create(string(sqlite3_errmsg(Db)));
    sqlite3_bind_int64(Stmt, 1, FWatermark);
    // Contact names are optional; keep the stable remote UID for filtering.
    sqlite3_prepare_v2(Db,
      'SELECT remote_name FROM remotes WHERE remote_uid=? LIMIT 1', -1,
      @ContactStmt, nil);
    repeat
      Code := sqlite3_step(Stmt);
      if Code = SQLITE_DONE then Break;
      if Code <> SQLITE_ROW then
        raise Exception.Create(string(sqlite3_errmsg(Db)));
      with Events[Count] do
      begin
        Id := sqlite3_column_int64(Stmt, 0);
        Sender := ColumnText(Stmt, 1);
        Channel := ColumnText(Stmt, 2);
        Body := ColumnText(Stmt, 3);
        Outgoing := sqlite3_column_int(Stmt, 4) <> 0;
        Contact := Sender;
        if (ContactStmt <> nil) and not Outgoing and (Body <> '') then
        begin
          sqlite3_reset(ContactStmt);
          sqlite3_bind_text(ContactStmt, 1, PChar(Sender), Length(Sender),
            sqlite3_destructor_type(SQLITE_TRANSIENT));
          if sqlite3_step(ContactStmt) = SQLITE_ROW then
            if ColumnText(ContactStmt, 0) <> '' then Contact := ColumnText(ContactStmt, 0);
        end;
      end;
      Inc(Count);
    until Count = EVENT_BATCH_SIZE;
  finally
    sqlite3_finalize(ContactStmt);
    sqlite3_finalize(Stmt);
    sqlite3_close(Db);
  end;

  // Release the database read lock before Bluetooth I/O, which can block.
  for I := 0 to Count - 1 do
  begin
    if not Events[I].Outgoing and (Events[I].Body <> '') then
      if not Handler(Events[I]) then Break;
    FWatermark := Events[I].Id;
    Inc(Result);
  end;
end;

end.
