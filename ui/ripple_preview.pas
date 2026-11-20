unit ripple_preview;

{$mode objfpc}{$H+}

interface

uses Graphics, IntfGraphics, ripple_types;

function DecodePreview(const Data: TRippleBytes): TLazIntfImage;
procedure LoadPreviewPicture(Picture: TPicture; const Data: TRippleBytes);

implementation

uses Classes, SysUtils, FPImage, FPReadPNG, FPReadJPEG, FPReadGIF, GraphType,
  ripple_images;

function DecodePreview(const Data: TRippleBytes): TLazIntfImage;
var Stream: TMemoryStream; Reader: TFPCustomImageReader;
  Description: TRawImageDescription;
begin
  if not SafePreview(Data) then raise Exception.Create('Unsupported or oversized screenshot');
  Result := TLazIntfImage.Create(0, 0);
  try
    // GTK2 cannot copy a depth-1 PNG drawable onto a colour window with XCopyArea.
    // Decode into RGBA pixels before creating any native bitmap handles.
    Description.Init_BPP32_B8G8R8A8_BIO_TTB(0, 0);
    Result.DataDescription := Description;
    case Data[0] of
      $89: Reader := TFPReaderPNG.Create;
      $47: Reader := TFPReaderGIF.Create;
      else Reader := TFPReaderJPEG.Create;
    end;
    try
      Stream := TMemoryStream.Create;
      try
        Stream.WriteBuffer(Data[0], Length(Data));
        Stream.Position := 0;
        Result.LoadFromStream(Stream, Reader);
      finally Stream.Free; end;
    finally Reader.Free; end;
  except
    Result.Free;
    raise;
  end;
end;

procedure LoadPreviewPicture(Picture: TPicture; const Data: TRippleBytes);
var Pixels: TLazIntfImage; Bitmap: TBitmap;
begin
  Pixels := DecodePreview(Data);
  try
    Bitmap := TBitmap.Create;
    try
      Bitmap.LoadFromIntfImage(Pixels);
      Picture.Assign(Bitmap);
    finally Bitmap.Free; end;
  finally Pixels.Free; end;
end;

end.
