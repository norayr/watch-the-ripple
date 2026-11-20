unit ripple_gallery;

{$mode objfpc}{$H+}

interface

const GalleryPageSize = 9;

function GalleryColumns(Width: Integer): Integer;
function GalleryPageCount(Count: Integer): Integer;
function GalleryPageStart(Page, Count: Integer): Integer;

implementation

function GalleryColumns(Width: Integer): Integer;
begin
  Result := (Width - 16) div 200;
  if Result < 1 then Result := 1;
  if Result > 3 then Result := 3;
end;

function GalleryPageCount(Count: Integer): Integer;
begin
  Result := (Count + GalleryPageSize - 1) div GalleryPageSize;
  if Result < 1 then Result := 1;
end;

function GalleryPageStart(Page, Count: Integer): Integer;
begin
  if Page < 0 then Page := 0;
  if Page >= GalleryPageCount(Count) then Page := GalleryPageCount(Count) - 1;
  Result := Page * GalleryPageSize;
end;

end.
