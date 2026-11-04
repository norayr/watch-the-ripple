program test_pebble_protocol;

{$mode objfpc}{$H+}

uses SysUtils, pebble_protocol;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then raise Exception.Create(Msg);
end;

var Reply: TPebbleBytes;
begin
  Reply := PongForPing([0, 0, 0, 0, $2A]);
  Check(Length(Reply) = 5, 'five-byte ping reply length');
  Check((Reply[0] = 1) and (Reply[4] = $2A), 'pong opcode and cookie');
  Reply := PongForPing([0, $12, $34, $56, $78, 1]);
  Check(Length(Reply) = 5, 'idle flag is not echoed');
  Check((Reply[0] = 1) and (Reply[1] = $12) and (Reply[2] = $34) and
    (Reply[3] = $56) and (Reply[4] = $78), 'cookie bytes preserved');
  Check(PongForPing([1, 0, 0, 0, $2A]) = nil, 'do not reply to a pong');
  Check(PongForPing([2, 0, 0, 0, $2A]) = nil, 'unknown opcode ignored');
  Check(PongForPing([0, 0, 0, 0]) = nil, 'short ping ignored');
  Check(PongForPing([]) = nil, 'empty ping ignored');
  WriteLn('Pebble protocol tests passed');
end.
