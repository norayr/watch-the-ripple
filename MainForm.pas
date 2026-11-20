unit MainForm;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Dialogs,
  Graphics, ripple_types, ripple_operations, ripple_images
  {$IFDEF LCLGTK2}
  , x, Gtk2, Gdk2, Gdk2x, xatom
  {$ENDIF};

type
  TGalleryCard = record
    Panel: TPanel;
    Image: TImage;
    Title, Author, Warning: TLabel;
    Open: TButton;
  end;
  TFormMain = class(TForm)
  private
    FMode, FSource: TComboBox;
    FRefresh, FDetect, FInstall, FRemove, FSearchButton: TButton;
    FPrevious, FNext, FImagePrevious, FImageNext: TButton;
    FSearch: TEdit;
    FSearchPanel, FPager, FImagePanel: TPanel;
    FPageLabel, FImageLabel: TLabel;
    FTabs: TPageControl;
    FGalleryTab, FListTab, FDetailsTab: TTabSheet;
    FGallery: TScrollBox;
    FCards: array of TGalleryCard;
    FList: TListView;
    FDetails: TMemo;
    FPicture: TImage;
    FStatus: TLabel;
    FProgress: TProgressBar;
    FTimer: TTimer;
    FWorker: TRippleWorker;
    FPreview: TPreviewWorker;
    FOperation: TRippleOperation;
    FItems: TRippleItems;
    FSelected, FPage, FRequestedPage, FImageIndex, FGeneration: Integer;
    FQuery, FRequestedQuery: string;
    FHasMore, FDetailsReady, FClosing, FPopulating, FLayout: Boolean;
    FRemote, FRequestedFeatured: Boolean;
    FWinPropertySet: Boolean;
    procedure CreateControls;
    procedure FormActivate(Sender: TObject);
    procedure Closing(Sender: TObject; var CanClose: Boolean);
    procedure RefreshClick(Sender: TObject);
    procedure ModeChanged(Sender: TObject);
    procedure SourceChanged(Sender: TObject);
    procedure DetectClick(Sender: TObject);
    procedure InstallClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
    procedure CardClick(Sender: TObject);
    procedure ListClick(Sender: TObject);
    procedure PageClick(Sender: TObject);
    procedure ImageClick(Sender: TObject);
    procedure SearchKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TabChanged(Sender: TObject);
    procedure LayoutGallery(Sender: TObject);
    procedure LayoutDetails(Sender: TObject);
    procedure Tick(Sender: TObject);
    procedure UpdateButtons;
    procedure FillList;
    procedure ShowItem(Index: Integer);
    procedure ShowDetails;
    procedure RequestPreviews;
    procedure ReadPreviews;
    function PageStart: Integer;
    procedure BeginOperation(Operation: TRippleOperation);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var FormMain: TFormMain;

implementation

uses Math, ripple_gallery;

constructor TFormMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 1);
  Caption := 'Ripple';
  Width := 800;
  Height := 480;
  Constraints.MinWidth := 360;
  Constraints.MinHeight := 360;
  Position := poScreenCenter;
  FSelected := -1;
  FRemote := True;
  OnActivate := @FormActivate;
  OnCloseQuery := @Closing;
  CreateControls;
  FPreview := TPreviewWorker.Create;
  FTimer.Enabled := True;
  RefreshClick(nil);
end;

destructor TFormMain.Destroy;
begin
  if FTimer <> nil then FTimer.Enabled := False;
  if FWorker <> nil then
  begin
    FWorker.WaitFor;
    FWorker.Free;
  end;
  FPreview.Free;
  inherited Destroy;
end;

procedure TFormMain.CreateControls;
var ModePanel, Actions, ImageActions: TPanel; I: Integer;

  function Panel(Parent: TWinControl; Alignment: TAlign; Size: Integer): TPanel;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := Parent;
    Result.Align := Alignment;
    Result.Height := Size;
    Result.BevelOuter := bvNone;
    Result.Caption := '';
  end;

  function Button(Parent: TWinControl; const Text: string; Handler: TNotifyEvent;
    Size: Integer): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Parent;
    Result.Caption := Text;
    Result.Width := Size;
    Result.Left := 10000;
    Result.Align := alLeft;
    Result.OnClick := Handler;
  end;

  function Tab(const Text: string): TTabSheet;
  begin
    Result := TTabSheet.Create(Self);
    Result.PageControl := FTabs;
    Result.Caption := Text;
  end;

  function CardLabel(Parent: TWinControl; Y, Size: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Parent;
    Result.AutoSize := False;
    Result.SetBounds(8, Y, 180, Size);
    Result.WordWrap := True;
  end;

begin
  ModePanel := Panel(Self, alTop, 40);
  FSource := TComboBox.Create(Self);
  FSource.Parent := ModePanel;
  FSource.Width := 115;
  FSource.Align := alRight;
  FSource.Style := csDropDownList;
  FSource.Items.Add('All');
  FSource.Items.Add('Featured');
  FSource.ItemIndex := 0;
  FSource.OnChange := @SourceChanged;
  FMode := TComboBox.Create(Self);
  FMode.Parent := ModePanel;
  FMode.Align := alClient;
  FMode.Style := csDropDownList;
  FMode.Items.Add('Watchfaces');
  FMode.Items.Add('Watch apps');
  FMode.Items.Add('Installed / Ripple records');
  FMode.ItemIndex := 0;
  FMode.OnChange := @ModeChanged;

  Actions := Panel(Self, alTop, 40);
  Actions.Top := 40;
  FRefresh := Button(Actions, 'Refresh', @RefreshClick, 82);
  FDetect := Button(Actions, 'Detect watch', @DetectClick, 110);
  FInstall := Button(Actions, 'Install', @InstallClick, 78);
  FRemove := Button(Actions, 'Remove', @RemoveClick, 82);
  FRemove.ShowHint := True;
  FRemove.Hint := 'Remove from the watch if present, including apps installed by another companion';

  FSearchPanel := Panel(Self, alTop, 40);
  FSearchPanel.Top := 80;
  FSearchButton := Button(FSearchPanel, 'Search', @RefreshClick, 82);
  FSearchButton.Align := alRight;
  FSearch := TEdit.Create(Self);
  FSearch.Parent := FSearchPanel;
  FSearch.Align := alClient;
  FSearch.TextHint := 'Search Rebble; empty to browse';
  FSearch.OnKeyDown := @SearchKey;

  FPager := Panel(Self, alTop, 36);
  FPager.Top := 120;
  FPrevious := Button(FPager, 'Previous', @PageClick, 92);
  FNext := Button(FPager, 'Next', @PageClick, 78);
  FPageLabel := TLabel.Create(Self);
  FPageLabel.Parent := FPager;
  FPageLabel.Align := alClient;
  FPageLabel.Layout := tlCenter;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 42;
  FStatus.WordWrap := True;
  FStatus.Caption := 'Ready';
  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := Self;
  FProgress.Align := alBottom;
  FProgress.Height := 8;

  FTabs := TPageControl.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align := alClient;
  FGalleryTab := Tab('Gallery');
  FListTab := Tab('List');
  FDetailsTab := Tab('Details');
  FGallery := TScrollBox.Create(Self);
  FGallery.Parent := FGalleryTab;
  FGallery.Align := alClient;
  FGallery.HorzScrollBar.Visible := False;
  SetLength(FCards, GalleryPageSize);
  for I := 0 to High(FCards) do
    with FCards[I] do
    begin
      Panel := TPanel.Create(Self);
      Panel.Parent := FGallery;
      Panel.Caption := '';
      Panel.Visible := False;
      Image := TImage.Create(Self);
      Image.Parent := Panel;
      Image.SetBounds(8, 8, 180, 168);
      Image.Stretch := True;
      Image.Proportional := True;
      Image.Center := True;
      Image.Cursor := crHandPoint;
      Image.OnClick := @CardClick;
      Title := CardLabel(Panel, 180, 38);
      Title.Font.Style := [fsBold];
      Title.OnClick := @CardClick;
      Title.Cursor := crHandPoint;
      Author := CardLabel(Panel, 220, 20);
      Warning := CardLabel(Panel, 242, 32);
      Open := Button(Panel, 'Details', @CardClick, 180);
      Open.Align := alNone;
      Open.SetBounds(8, 276, 180, 32);
    end;
  FGallery.OnResize := @LayoutGallery;

  FList := TListView.Create(Self);
  FList.Parent := FListTab;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.RowSelect := True;
  FList.ReadOnly := True;
  FList.HideSelection := False;
  FList.OnSelectItem := @Selected;
  FList.OnClick := @ListClick;
  with FList.Columns.Add do begin Caption := 'Name'; Width := 260; end;
  with FList.Columns.Add do begin Caption := 'Author'; Width := 160; end;
  with FList.Columns.Add do begin Caption := 'Version'; Width := 80; end;

  FImagePanel := Panel(FDetailsTab, alLeft, 216);
  FImagePanel.Width := 200;
  ImageActions := Panel(FImagePanel, alBottom, 36);
  FImagePrevious := Button(ImageActions, '<', @ImageClick, 44);
  FImageNext := Button(ImageActions, '>', @ImageClick, 44);
  FImageLabel := TLabel.Create(Self);
  FImageLabel.Parent := ImageActions;
  FImageLabel.Align := alClient;
  FImageLabel.Layout := tlCenter;
  FPicture := TImage.Create(Self);
  FPicture.Parent := FImagePanel;
  FPicture.Align := alClient;
  FPicture.Stretch := True;
  FPicture.Proportional := True;
  FPicture.Center := True;
  FDetails := TMemo.Create(Self);
  FDetails.Parent := FDetailsTab;
  FDetails.Align := alClient;
  FDetails.ReadOnly := True;
  FDetails.ScrollBars := ssVertical;
  FDetailsTab.OnResize := @LayoutDetails;
  FTabs.ActivePage := FGalleryTab;
  FTabs.OnChange := @TabChanged;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;
  FTimer.Enabled := False;
  FTimer.OnTimer := @Tick;
  UpdateButtons;
end;

procedure TFormMain.FormActivate(Sender: TObject);
{$IFDEF LCLGTK2}
var Widget: PGtkWidget; Atom: TGdkAtom; Value: Cardinal;
{$ENDIF}
begin
  {$IFDEF LCLGTK2}
  if FWinPropertySet then Exit;
  Widget := PGtkWidget(Handle);
  if (Widget <> nil) and (Widget^.window <> nil) then
  begin
    Atom := gdk_atom_intern('_HILDON_PORTRAIT_MODE_SUPPORT', False);
    Value := 1;
    if Atom <> 0 then
    begin
      gdk_property_change(Widget^.window, Atom,
        gdk_x11_xatom_to_atom(XA_CARDINAL), 32,
        GDK_PROP_MODE_REPLACE, @Value, 1);
      FWinPropertySet := True;
    end;
  end;
  {$ENDIF}
end;

procedure TFormMain.Closing(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := False;
  if FWorker <> nil then
  begin
    MessageDlg('Ripple', 'Please wait for the current operation to finish so wtrd can be restored.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  FClosing := True;
  FPreview.Stop;
  CanClose := FPreview.Stopped;
  if not CanClose then FStatus.Caption := 'Stopping screenshot downloads…';
  UpdateButtons;
end;

procedure TFormMain.BeginOperation(Operation: TRippleOperation);
var Item: TRippleItem;
begin
  if (FWorker <> nil) or FClosing then Exit;
  Item := Default(TRippleItem);
  if (FSelected >= 0) and (FSelected < Length(FItems)) then Item := FItems[FSelected];
  FOperation := Operation;
  FWorker := TRippleWorker.Create(Operation, Item, FRequestedQuery, FRequestedPage,
    FRequestedFeatured);
  FStatus.Caption := 'Working…';
  FProgress.Position := 0;
  FWorker.Start;
  UpdateButtons;
end;

procedure TFormMain.RefreshClick(Sender: TObject);
begin
  if FWorker <> nil then Exit;
  FRequestedQuery := Trim(FSearch.Text);
  FRequestedPage := 0;
  if FRequestedQuery <> '' then FSource.ItemIndex := 0;
  FRequestedFeatured := FSource.ItemIndex = 1;
  case FMode.ItemIndex of
    0: BeginOperation(roWatchfaces);
    1: BeginOperation(roApps);
    2: BeginOperation(roInstalled);
  end;
end;

procedure TFormMain.ModeChanged(Sender: TObject);
begin
  FItems := nil;
  FQuery := '';
  FSearch.Clear;
  FPage := 0;
  FHasMore := False;
  FRemote := (FMode.ItemIndex <> 2) and (FSource.ItemIndex = 0);
  if FMode.ItemIndex = 2 then FTabs.ActivePage := FListTab
  else FTabs.ActivePage := FGalleryTab;
  FillList;
  RefreshClick(Sender);
end;

procedure TFormMain.SourceChanged(Sender: TObject);
begin
  if FWorker <> nil then Exit;
  FSearch.Clear;
  RefreshClick(Sender);
end;

procedure TFormMain.DetectClick(Sender: TObject);
begin BeginOperation(roIdentify); end;

procedure TFormMain.SearchKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = 13 then begin Key := 0; RefreshClick(Sender); end;
end;

procedure TFormMain.PageClick(Sender: TObject);
var NewPage: Integer;
begin
  if FWorker <> nil then Exit;
  NewPage := FPage;
  if Sender = FNext then Inc(NewPage) else Dec(NewPage);
  if NewPage < 0 then Exit;
  if FRemote then
  begin
    FRequestedPage := NewPage;
    FRequestedQuery := FQuery;
    FRequestedFeatured := False;
    if FMode.ItemIndex = 0 then BeginOperation(roWatchfaces) else BeginOperation(roApps);
  end
  else
  begin
    if NewPage >= GalleryPageCount(Length(FItems)) then Exit;
    FPage := NewPage;
    FillList;
  end;
end;

procedure TFormMain.InstallClick(Sender: TObject);
begin
  if not FInstall.Enabled then Exit;
  if MessageDlg('Install on watch', 'Install ' + FItems[FSelected].Title +
    '? Notifications pause temporarily during watch access, then resume if wtrd was running. Phone-side JavaScript and configuration pages are not supported.',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then BeginOperation(roInstall);
end;

procedure TFormMain.RemoveClick(Sender: TObject);
var Prompt: string;
begin
  if not FRemove.Enabled then Exit;
  Prompt := 'Remove ' + FItems[FSelected].Title + ' from the watch, if present?';
  if FMode.ItemIndex <> 2 then Prompt := Prompt + LineEnding +
    'This uses the catalog UUID and does not check whether the app is installed.';
  if MessageDlg('Remove from watch', Prompt, mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    BeginOperation(roRemove);
end;

procedure TFormMain.UpdateButtons;
var Idle, HasItem, DetailsView: Boolean;
begin
  Idle := (FWorker = nil) and not FClosing;
  HasItem := (FSelected >= 0) and (FSelected < Length(FItems));
  DetailsView := FTabs.ActivePage = FDetailsTab;
  FMode.Enabled := Idle;
  FSource.Enabled := Idle;
  FSource.Visible := FMode.ItemIndex <> 2;
  FRefresh.Enabled := Idle;
  FDetect.Enabled := Idle;
  FSearch.Enabled := Idle;
  FSearchButton.Enabled := Idle;
  FList.Enabled := Idle;
  FGallery.Enabled := Idle;
  FTabs.Enabled := Idle;
  FSearchPanel.Visible := (FMode.ItemIndex <> 2) and not DetailsView;
  FPager.Visible := not DetailsView;
  FInstall.Enabled := Idle and HasItem and DetailsView and FDetailsReady and (FMode.ItemIndex <> 2);
  if FInstall.Enabled then FInstall.Enabled := (FItems[FSelected].DownloadURL <> '') and
    not FItems[FSelected].Incompatible;
  FRemove.Enabled := Idle and HasItem and DetailsView;
  if FRemove.Enabled then FRemove.Enabled := FItems[FSelected].UUID <> '';
  FPrevious.Enabled := Idle and (FPage > 0);
  if FRemote then
  begin
    FNext.Enabled := Idle and FHasMore;
    if FQuery <> '' then FPageLabel.Caption := 'Search page ' + IntToStr(FPage + 1)
    else FPageLabel.Caption := 'All — page ' + IntToStr(FPage + 1);
  end
  else
  begin
    FNext.Enabled := Idle and (FPage + 1 < GalleryPageCount(Length(FItems)));
    FPageLabel.Caption := 'Page ' + IntToStr(FPage + 1) + ' / ' +
      IntToStr(GalleryPageCount(Length(FItems))) + ' (' + IntToStr(Length(FItems)) + ' items)';
  end;
  FImagePrevious.Enabled := Idle and HasItem and (FImageIndex > 0);
  FImageNext.Enabled := False;
  if HasItem then FImageNext.Enabled := Idle and
    (FImageIndex + 1 < Length(FItems[FSelected].Screenshots));
end;

function TFormMain.PageStart: Integer;
begin
  if FRemote then Result := 0 else Result := GalleryPageStart(FPage, Length(FItems));
end;

procedure TFormMain.Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
begin
  if IsSelected and not FPopulating and (FWorker = nil) then
    ShowItem(PageStart + Item.Index);
end;

procedure TFormMain.CardClick(Sender: TObject);
begin
  if FWorker = nil then ShowItem(TControl(Sender).Tag);
end;

procedure TFormMain.ListClick(Sender: TObject);
begin
  if (FWorker = nil) and (FList.Selected <> nil) then ShowItem(PageStart + FList.Selected.Index);
end;

procedure TFormMain.ShowItem(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FItems)) then Exit;
  FSelected := Index;
  FImageIndex := 0;
  FDetailsReady := (FMode.ItemIndex = 2) or (FItems[Index].StoreID = '');
  ShowDetails;
  FTabs.ActivePage := FDetailsTab;
  TabChanged(nil);
  if not FDetailsReady then BeginOperation(roDetails);
end;

procedure TFormMain.ShowDetails;
var A: TRippleItem; DetailsText: string;
begin
  if (FSelected < 0) or (FSelected >= Length(FItems)) then Exit;
  A := FItems[FSelected];
  DetailsText := A.Title + ' — ' + A.Author;
  if FMode.ItemIndex <> 2 then DetailsText := DetailsText + LineEnding +
    'Installation status: unknown. Remove sends this app UUID to the watch if present.';
  if A.Version <> '' then DetailsText := DetailsText + LineEnding + 'Version: ' + A.Version;
  if A.Incompatible then DetailsText := DetailsText + LineEnding + 'Not compatible with the detected watch.';
  if A.Configurable then DetailsText := DetailsText + LineEnding +
    'Configuration requires phone-side JavaScript; Ripple cannot open its settings or supply API keys.';
  if A.UsesLocation then DetailsText := DetailsText + LineEnding +
    'Uses location. Weather/location updates may require phone-side JavaScript, which Ripple does not run.';
  if A.Capabilities <> '' then DetailsText := DetailsText + LineEnding + 'Capabilities: ' + A.Capabilities;
  DetailsText := DetailsText + LineEnding + LineEnding + A.Description + LineEnding + LineEnding + A.UUID;
  if A.StoreURL <> '' then DetailsText := DetailsText + LineEnding + A.StoreURL;
  FDetails.Text := DetailsText;
  if Length(A.Screenshots) = 0 then FImageLabel.Caption := 'No screenshot'
  else FImageLabel.Caption := IntToStr(FImageIndex + 1) + ' / ' + IntToStr(Length(A.Screenshots));
  UpdateButtons;
end;

procedure TFormMain.ImageClick(Sender: TObject);
begin
  if not TButton(Sender).Enabled then Exit;
  if Sender = FImageNext then Inc(FImageIndex) else Dec(FImageIndex);
  ShowDetails;
  RequestPreviews;
end;

procedure TFormMain.TabChanged(Sender: TObject);
begin
  UpdateButtons;
  LayoutGallery(nil);
  LayoutDetails(nil);
  RequestPreviews;
end;

procedure TFormMain.FillList;
var I, Index: Integer; Item: TListItem;
begin
  FSelected := -1;
  FDetailsReady := False;
  FDetails.Clear;
  FPicture.Picture.Clear;
  FImageLabel.Caption := 'Choose an app';
  FGallery.VertScrollBar.Position := 0;
  FPopulating := True;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to High(FCards) do
    begin
      Index := PageStart + I;
      FCards[I].Panel.Visible := Index < Length(FItems);
      FCards[I].Image.Picture.Clear;
      if Index >= Length(FItems) then Continue;
      FCards[I].Title.Caption := FItems[Index].Title;
      FCards[I].Author.Caption := FItems[Index].Author;
      FCards[I].Warning.Caption := '';
      if FItems[Index].Configurable then FCards[I].Warning.Caption := 'Requires configuration';
      if FItems[Index].UsesLocation then FCards[I].Warning.Caption := 'Uses location / phone support';
      if FItems[Index].Incompatible then FCards[I].Warning.Caption := 'Incompatible watch hardware';
      FCards[I].Image.Tag := Index;
      FCards[I].Title.Tag := Index;
      FCards[I].Open.Tag := Index;
      Item := FList.Items.Add;
      Item.Caption := FItems[Index].Title;
      Item.SubItems.Add(FItems[Index].Author);
      Item.SubItems.Add(FItems[Index].Version);
    end;
  finally
    FList.Items.EndUpdate;
    FPopulating := False;
  end;
  LayoutGallery(nil);
  UpdateButtons;
  RequestPreviews;
end;

procedure TFormMain.LayoutGallery(Sender: TObject);
var Columns, CardWidth, I, Y: Integer;
begin
  if FLayout or (FGallery = nil) then Exit;
  FLayout := True;
  try
    Columns := GalleryColumns(FGallery.ClientWidth);
    CardWidth := Max(1, (FGallery.ClientWidth - 16) div Columns - 8);
    for I := 0 to High(FCards) do
    begin
      Y := 8 + (I div Columns) * 324 - FGallery.VertScrollBar.Position;
      FCards[I].Panel.SetBounds(8 + (I mod Columns) * (CardWidth + 8), Y, CardWidth, 316);
      FCards[I].Image.Width := Max(1, CardWidth - 16);
      FCards[I].Title.Width := Max(1, CardWidth - 16);
      FCards[I].Author.Width := Max(1, CardWidth - 16);
      FCards[I].Warning.Width := Max(1, CardWidth - 16);
      FCards[I].Open.Width := Max(1, CardWidth - 16);
    end;
  finally FLayout := False; end;
end;

procedure TFormMain.LayoutDetails(Sender: TObject);
begin
  if (FImagePanel = nil) or FLayout then Exit;
  FLayout := True;
  try
    if FDetailsTab.ClientWidth < 560 then
    begin
      FImagePanel.Align := alTop;
      FImagePanel.Height := 212;
    end
    else
    begin
      FImagePanel.Align := alLeft;
      FImagePanel.Width := 200;
    end;
  finally FLayout := False; end;
end;

procedure TFormMain.RequestPreviews;
var URLs: TRippleStrings; I, Index: Integer;
begin
  if (FPreview = nil) or FClosing then Exit;
  URLs := nil;
  Inc(FGeneration);
  if FTabs.ActivePage = FGalleryTab then
  begin
    SetLength(URLs, Min(GalleryPageSize, Length(FItems) - PageStart));
    for I := 0 to High(URLs) do
    begin
      Index := PageStart + I;
      if Length(FItems[Index].Screenshots) > 0 then URLs[I] := FItems[Index].Screenshots[0];
    end;
  end
  else if FTabs.ActivePage = FDetailsTab then
  begin
    FPicture.Picture.Clear;
    if (FSelected >= 0) and (FSelected < Length(FItems)) and
      (FImageIndex >= 0) and (FImageIndex < Length(FItems[FSelected].Screenshots)) then
    begin
      SetLength(URLs, 1);
      URLs[0] := FItems[FSelected].Screenshots[FImageIndex];
    end;
  end;
  FPreview.Request(URLs, FGeneration);
end;

procedure TFormMain.ReadPreviews;
var Results: TPreviewResults; R: TPreviewResult; Stream: TMemoryStream;
  Image: TImage;
begin
  Results := FPreview.TakeResults;
  for R in Results do
  begin
    if R.Generation <> FGeneration then Continue;
    Image := nil;
    if FTabs.ActivePage = FDetailsTab then Image := FPicture
    else if (FTabs.ActivePage = FGalleryTab) and (R.Index >= 0) and
      (R.Index < Length(FCards)) then Image := FCards[R.Index].Image;
    if Image = nil then Continue;
    Image.Hint := R.ErrorText;
    if R.ErrorText = '' then
    begin
      Stream := TMemoryStream.Create;
      try
        try
          if Length(R.Data) > 0 then Stream.WriteBuffer(R.Data[0], Length(R.Data));
          Stream.Position := 0;
          Image.Picture.LoadFromStream(Stream);
        except on E: Exception do Image.Hint := 'Screenshot could not be decoded: ' + E.Message; end;
      finally Stream.Free; end;
    end;
    Image.ShowHint := Image.Hint <> '';
    if Image = FPicture then
      if Image.Hint <> '' then FImageLabel.Caption := 'Unavailable';
  end;
end;

procedure TFormMain.Tick(Sender: TObject);
var Done, ReloadCatalog: Boolean; StatusText, ErrorText: string; Percent: Integer;
begin
  if FClosing then
  begin
    if FPreview.Stopped then Close;
    Exit;
  end;
  ReadPreviews;
  if FWorker = nil then Exit;
  FWorker.Snapshot(Done, StatusText, Percent);
  FStatus.Caption := StatusText;
  FProgress.Position := Percent;
  if not Done then Exit;
  FWorker.WaitFor;
  ErrorText := FWorker.ErrorText;
  ReloadCatalog := False;
  if ErrorText = '' then
  begin
    case FOperation of
      roDetails:
        if (FSelected >= 0) and (Length(FWorker.Items) = 1) then
        begin
          FItems[FSelected] := FWorker.Items[0];
          FDetailsReady := True;
          FImageIndex := 0;
          ShowDetails;
          RequestPreviews;
        end;
      roIdentify: ReloadCatalog := FMode.ItemIndex <> 2;
      else
        begin
          if FOperation in [roInstall, roRemove] then
          begin
            FMode.ItemIndex := 2;
            FSearch.Clear;
            FRequestedQuery := '';
            FRequestedPage := 0;
          end;
          FItems := FWorker.Items;
          if FOperation = roInstalled then
          begin
            FRequestedQuery := '';
            FRequestedPage := 0;
          end;
          FQuery := FRequestedQuery;
          FPage := FRequestedPage;
          FRemote := (FMode.ItemIndex <> 2) and not FRequestedFeatured;
          FHasMore := FWorker.HasMore;
          if FMode.ItemIndex = 2 then FTabs.ActivePage := FListTab
          else if FTabs.ActivePage = FDetailsTab then FTabs.ActivePage := FGalleryTab;
          FillList;
        end;
    end;
    FStatus.Caption := FWorker.Note;
    if Length(FItems) = 0 then FStatus.Caption := FStatus.Caption + '; no items found';
    FProgress.Position := 100;
  end
  else FStatus.Caption := ErrorText;
  FreeAndNil(FWorker);
  UpdateButtons;
  if ErrorText <> '' then MessageDlg('Ripple', ErrorText, mtError, [mbOK], 0);
  if ReloadCatalog then RefreshClick(nil);
end;

end.
