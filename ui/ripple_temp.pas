unit ripple_temp;

{$mode objfpc}{$H+}

interface

uses Classes;

type
  TTempPBWFile = class(THandleStream)
  private
    FDescriptor: LongInt;
    FFilename: string;
  public
    constructor Create(const Directory: string = '');
    destructor Destroy; override;
    property Filename: string read FFilename;
  end;

implementation

uses SysUtils, BaseUnix, Linux;

constructor TTempPBWFile.Create(const Directory: string);
var Candidate: string; Attempt, Code: Integer;
begin
  FDescriptor := -1;
  for Attempt := 1 to 100 do
  begin
    Candidate := GetTempFileName(Directory, 'ripple-pbw-');
    // Exclusive creation prevents overwriting another file in a shared temporary directory.
    FDescriptor := fpOpen(Candidate, O_RDWR or O_CREAT or O_EXCL or O_CLOEXEC, &600);
    if FDescriptor >= 0 then
    begin
      FFilename := Candidate;
      inherited Create(FDescriptor);
      Exit;
    end;
    Code := fpGetErrno;
    if Code <> ESysEEXIST then
      raise Exception.Create('Cannot create temporary PBW file in ' +
        ExtractFilePath(Candidate) + ': ' + SysErrorMessage(Code));
  end;
  raise Exception.Create('Cannot reserve a temporary PBW file');
end;

destructor TTempPBWFile.Destroy;
begin
  if FDescriptor >= 0 then fpClose(FDescriptor);
  if FFilename <> '' then DeleteFile(FFilename);
  inherited Destroy;
end;

end.
