unit ripple_types;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  TRippleBytes = array of Byte;
  TRippleItem = record
    UUID, Title, Author, Description, DownloadURL, Version: string;
    Bank, AppID, Flags: Cardinal;
  end;
  TRippleItems = array of TRippleItem;
  TRippleRegistered = procedure(const Item: TRippleItem) of object;
  TWatchInfo = record
    Firmware, Platform, Address: string;
    Major: Integer;
  end;
  TRippleProgress = procedure(const Text: string; Percent: Integer) of object;

implementation

end.
