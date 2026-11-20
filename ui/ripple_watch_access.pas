unit ripple_watch_access;

{$mode objfpc}{$H+}

interface

type
  TWatchAccess = class
  private
    FDescriptor: LongInt;
    FLocked: Boolean;
  public
    constructor Create(const Filename: string);
    destructor Destroy; override;
  end;

implementation

uses SysUtils, BaseUnix, Unix, Linux;

constructor TWatchAccess.Create(const Filename: string);
var Code: Integer;
begin
  inherited Create;
  FDescriptor := -1;
  // Set close-on-exec atomically so control commands cannot pass the lock to wtrd.
  FDescriptor := fpOpen(Filename, O_RDWR or O_CREAT or O_CLOEXEC, &600);
  if FDescriptor < 0 then raise Exception.Create('Cannot open watch access lock');
  if fpFlock(FDescriptor, LOCK_EX or LOCK_NB) <> 0 then
  begin
    Code := fpGetErrno;
    if (Code = ESysEAGAIN) or (Code = ESysEWOULDBLOCK) then
      raise Exception.Create('Another Ripple window is using the watch');
    raise Exception.Create('Cannot lock watch access: ' + SysErrorMessage(Code));
  end;
  FLocked := True;
end;

destructor TWatchAccess.Destroy;
begin
  if FDescriptor >= 0 then
  begin
    if FLocked then fpFlock(FDescriptor, LOCK_UN);
    fpClose(FDescriptor);
  end;
  inherited Destroy;
end;

end.
