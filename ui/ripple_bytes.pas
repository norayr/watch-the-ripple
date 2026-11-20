unit ripple_bytes;

{$mode objfpc}{$H+}

interface

uses SysUtils, ripple_types;

function Bytes(const Values: array of Byte): TRippleBytes;
function Join(const A, B: TRippleBytes): TRippleBytes;
function U16LE(V: Word): TRippleBytes;
function U16BE(V: Word): TRippleBytes;
function U32LE(V: Cardinal): TRippleBytes;
function U32BE(V: Cardinal): TRippleBytes;
function Read16BE(const B: TRippleBytes; Offset: Integer): Word;
function Read16LE(const B: TRippleBytes; Offset: Integer): Word;
function Read32BE(const B: TRippleBytes; Offset: Integer): Cardinal;
function Read32LE(const B: TRippleBytes; Offset: Integer): Cardinal;
function FixedText(const B: TRippleBytes; Offset, Count: Integer): string;
function UUIDBytes(const S: string): TRippleBytes;
function UUIDText(const B: TRippleBytes; Offset: Integer): string;
procedure RequireBytes(const B: TRippleBytes; Offset, Count: Integer);

implementation

procedure RequireBytes(const B: TRippleBytes; Offset, Count: Integer);
begin
  if (Offset < 0) or (Count < 0) or (Offset > Length(B) - Count) then
    raise Exception.Create('Truncated Pebble data');
end;

function Bytes(const Values: array of Byte): TRippleBytes;
var I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Values));
  for I := 0 to High(Values) do Result[I] := Values[I];
end;

function Join(const A, B: TRippleBytes): TRippleBytes;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function U16LE(V: Word): TRippleBytes;
begin Result := Bytes([V and $FF, V shr 8]); end;
function U16BE(V: Word): TRippleBytes;
begin Result := Bytes([V shr 8, V and $FF]); end;
function U32LE(V: Cardinal): TRippleBytes;
begin Result := Join(U16LE(V and $FFFF), U16LE(V shr 16)); end;
function U32BE(V: Cardinal): TRippleBytes;
begin Result := Join(U16BE(V shr 16), U16BE(V and $FFFF)); end;

function Read16BE(const B: TRippleBytes; Offset: Integer): Word;
begin
  RequireBytes(B, Offset, 2);
  Result := (Word(B[Offset]) shl 8) or B[Offset + 1];
end;
function Read16LE(const B: TRippleBytes; Offset: Integer): Word;
begin
  RequireBytes(B, Offset, 2);
  Result := B[Offset] or (Word(B[Offset + 1]) shl 8);
end;
function Read32BE(const B: TRippleBytes; Offset: Integer): Cardinal;
begin Result := (Cardinal(Read16BE(B, Offset)) shl 16) or Read16BE(B, Offset + 2); end;
function Read32LE(const B: TRippleBytes; Offset: Integer): Cardinal;
begin Result := Read16LE(B, Offset) or (Cardinal(Read16LE(B, Offset + 2)) shl 16); end;

function FixedText(const B: TRippleBytes; Offset, Count: Integer): string;
var N: Integer;
begin
  RequireBytes(B, Offset, Count);
  N := 0;
  while (N < Count) and (B[Offset + N] <> 0) do Inc(N);
  SetLength(Result, N);
  if N > 0 then Move(B[Offset], Result[1], N);
end;

function UUIDBytes(const S: string): TRippleBytes;
var I, V: Integer; H: string;
begin
  if (Length(S) <> 36) or (S[9] <> '-') or (S[14] <> '-') or
    (S[19] <> '-') or (S[24] <> '-') then
    raise Exception.Create('Invalid app UUID');
  H := StringReplace(S, '-', '', [rfReplaceAll]);
  Result := nil;
  if Length(H) <> 32 then raise Exception.Create('Invalid app UUID');
  SetLength(Result, 16);
  for I := 0 to 15 do
  begin
    if not TryStrToInt('$' + Copy(H, I * 2 + 1, 2), V) then
      raise Exception.Create('Invalid app UUID');
    Result[I] := V;
  end;
end;

function UUIDText(const B: TRippleBytes; Offset: Integer): string;
var I: Integer;
begin
  RequireBytes(B, Offset, 16);
  Result := '';
  for I := 0 to 15 do
  begin
    if I in [4, 6, 8, 10] then Result := Result + '-';
    Result := Result + LowerCase(IntToHex(B[Offset + I], 2));
  end;
end;

end.
