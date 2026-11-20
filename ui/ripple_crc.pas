unit ripple_crc;

{$mode objfpc}{$H+}

interface

uses ripple_types;

function PebbleCRC(const Data: TRippleBytes): Cardinal;

implementation

function PebbleCRC(const Data: TRippleBytes): Cardinal;
var I, J, K: Integer; W: Cardinal;
begin
  Result := $FFFFFFFF;
  I := 0;
  while I < Length(Data) do
  begin
    W := 0;
    if Length(Data) - I >= 4 then
      for J := 0 to 3 do
        W := W or (Cardinal(Data[I + J]) shl (J * 8))
    else
      // The firmware folds the final partial word in byte order, right-aligned.
      for J := I to High(Data) do W := (W shl 8) or Data[J];
    Result := Result xor W;
    for K := 1 to 32 do
      if (Result and $80000000) <> 0 then
        Result := (Result shl 1) xor $04C11DB7
      else Result := Result shl 1;
    Inc(I, 4);
  end;
end;

end.
