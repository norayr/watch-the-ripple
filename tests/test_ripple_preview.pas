program test_ripple_preview;

{$mode objfpc}{$H+}

uses cthreads, Classes, SysUtils, FPImage, IntfGraphics, ripple_types, ripple_preview;

procedure Check(Condition: Boolean; const Message: string);
begin
  if not Condition then raise Exception.Create(Message);
end;

function Load(const Filename: string): TLazIntfImage;
var Stream: TFileStream; Data: TRippleBytes;
begin
  Stream := TFileStream.Create(Filename, fmOpenRead);
  try
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then Stream.ReadBuffer(Data[0], Length(Data));
    Result := DecodePreview(Data);
  finally Stream.Free; end;
end;

procedure TestFormat(const Root, Name: string);
var Pixels: TLazIntfImage; Color: TFPColor;
begin
  Pixels := Load(Root + '/' + Name + '.png');
  try
    Check((Pixels.Width = 3) and (Pixels.Height = 2), Name + ' dimensions');
    Check((Pixels.DataDescription.Depth = 32) and
      (Pixels.DataDescription.BitsPerPixel = 32) and
      (Pixels.DataDescription.AlphaPrec = 8) and
      (Pixels.DataDescription.MaskBitsPerPixel = 0), Name + ' RGBA drawable format');
    Color := Pixels.Colors[0, 0];
    if Name = 'mono' then
    begin
      Check((Color.Red = 0) and (Color.Green = 0) and (Color.Blue = 0) and
        (Color.Alpha = $FFFF), 'monochrome black is opaque');
      Color := Pixels.Colors[1, 0];
      Check((Color.Red = $FFFF) and (Color.Green = $FFFF) and
        (Color.Blue = $FFFF) and (Color.Alpha = $FFFF), 'monochrome white is opaque');
      Color := Pixels.Colors[0, 1];
      Check(Color.Red = $FFFF, 'packed monochrome row alignment');
    end
    else if Name = 'gray' then
      Check((Color.Red = 0) and (Color.Green = 0) and (Color.Blue = 0), 'grayscale black')
    else
      Check((Color.Red = $FFFF) and (Color.Green = 0) and (Color.Blue = 0) and
        (Color.Alpha = $FFFF), Name + ' red pixel');
    Color := Pixels.Colors[1, 0];
    if (Name = 'rgba') or (Name = 'palette-alpha') then
      Check(Color.Alpha = $8080, Name + ' partial alpha preserved')
    else Check(Color.Alpha = $FFFF, Name + ' opaque alpha');
    Color := Pixels.Colors[2, 0];
    if (Name = 'rgba') or (Name = 'palette-alpha') then
      Check(Color.Alpha = 0, Name + ' transparent alpha preserved');
  finally Pixels.Free; end;
end;

procedure TestInvalid(const Root: string);
var Pixels: TLazIntfImage; Failed: Boolean;
begin
  Failed := False;
  try Pixels := DecodePreview(nil); Pixels.Free; except Failed := True; end;
  Check(Failed, 'empty image rejected before decode');
  Failed := False;
  try Pixels := Load(Root + '/truncated.png'); Pixels.Free; except Failed := True; end;
  Check(Failed, 'truncated PNG decoder failure reported');
end;

begin
  TestFormat(ParamStr(1), 'mono');
  TestFormat(ParamStr(1), 'gray');
  TestFormat(ParamStr(1), 'palette');
  TestFormat(ParamStr(1), 'palette-alpha');
  TestFormat(ParamStr(1), 'rgb');
  TestFormat(ParamStr(1), 'rgba');
  TestInvalid(ParamStr(1));
  WriteLn('Ripple preview decoding tests passed');
end.
