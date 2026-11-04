unit pebble_protocol;

{$mode objfpc}{$H+}

interface

type
  TPebbleBytes = array of Byte;

function PongForPing(const Data: array of Byte): TPebbleBytes;

implementation

function PongForPing(const Data: array of Byte): TPebbleBytes;
begin
  Result := nil;
  // Opcode 0 requests a pong (opcode 1) with the same four-byte cookie.
  // Requests may include a trailing idle flag; it is not part of the reply.
  if (Length(Data) < 5) or (Data[0] <> 0) then Exit;
  SetLength(Result, 5);
  Result[0] := 1;
  Move(Data[1], Result[1], 4);
end;

end.
