unit MainForm;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Dialogs,
  ripple_types, ripple_operations
  {$IFDEF LCLGTK2}
  , x, Gtk2, Gdk2, Gdk2x, xatom
  {$ENDIF};

type
  TFormMain = class(TForm)
  private
    FMode: TComboBox;
    FRefresh, FDetect, FInstall, FRemove: TButton;
    FList: TListView;
    FDetails: TMemo;
    FStatus: TLabel;
    FProgress: TProgressBar;
    FTimer: TTimer;
    FWorker: TRippleWorker;
    FOperation: TRippleOperation;
    FItems: TRippleItems;
    FWinPropertySet: Boolean;
    procedure CreateControls;
    procedure FormActivate(Sender: TObject);
    procedure Closing(Sender: TObject; var CanClose: Boolean);
    procedure RefreshClick(Sender: TObject);
    procedure ModeChanged(Sender: TObject);
    procedure DetectClick(Sender: TObject);
    procedure InstallClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
    procedure Tick(Sender: TObject);
    procedure UpdateButtons;
    procedure FillList;
    procedure BeginOperation(Operation: TRippleOperation);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var FormMain: TFormMain;

implementation

constructor TFormMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner, 1);
  Caption := 'Ripple';
  Width := 800;
  Height := 480;
  Constraints.MinWidth := 360;
  Constraints.MinHeight := 360;
  Position := poScreenCenter;
  OnActivate := @FormActivate;
  OnCloseQuery := @Closing;
  CreateControls;
  RefreshClick(nil);
end;

destructor TFormMain.Destroy;
begin
  if FWorker <> nil then
  begin
    FWorker.WaitFor;
    FWorker.Free;
  end;
  inherited Destroy;
end;

procedure TFormMain.CreateControls;
var ModePanel, Actions: TPanel;

  function Button(Parent: TWinControl; const Text: string; Handler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Parent;
    Result.Caption := Text;
    Result.Width := 110;
    Result.Align := alLeft;
    Result.Left := 10000;
    Result.OnClick := Handler;
  end;

begin
  ModePanel := TPanel.Create(Self);
  ModePanel.Parent := Self;
  ModePanel.Align := alTop;
  ModePanel.Height := 48;
  ModePanel.BevelOuter := bvNone;
  ModePanel.Caption := '';
  FMode := TComboBox.Create(Self);
  FMode.Parent := ModePanel;
  FMode.Align := alClient;
  FMode.Style := csDropDownList;
  FMode.Items.Add('Watchfaces');
  FMode.Items.Add('Watch apps');
  FMode.Items.Add('Installed / Ripple records');
  FMode.ItemIndex := 0;
  FMode.OnChange := @ModeChanged;

  Actions := TPanel.Create(Self);
  Actions.Parent := Self;
  Actions.Align := alTop;
  Actions.Top := 48;
  Actions.Height := 48;
  Actions.BevelOuter := bvNone;
  Actions.Caption := '';
  FRefresh := Button(Actions, 'Refresh', @RefreshClick);
  FDetect := Button(Actions, 'Detect watch', @DetectClick);
  FInstall := Button(Actions, 'Install', @InstallClick);
  FRemove := Button(Actions, 'Remove', @RemoveClick);
  FRefresh.Width := 82;
  FDetect.Width := 110;
  FInstall.Width := 78;
  FRemove.Width := 82;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 50;
  FStatus.WordWrap := True;
  FStatus.Caption := 'Ready';
  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := Self;
  FProgress.Align := alBottom;
  FProgress.Height := 12;
  FDetails := TMemo.Create(Self);
  FDetails.Parent := Self;
  FDetails.Align := alBottom;
  FDetails.Height := 95;
  FDetails.ReadOnly := True;
  FDetails.ScrollBars := ssVertical;
  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.RowSelect := True;
  FList.ReadOnly := True;
  FList.HideSelection := False;
  FList.OnSelectItem := @Selected;
  with FList.Columns.Add do begin Caption := 'Name'; Width := 260; end;
  with FList.Columns.Add do begin Caption := 'Author'; Width := 160; end;
  with FList.Columns.Add do begin Caption := 'Version'; Width := 80; end;
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
  CanClose := FWorker = nil;
  if not CanClose then
    MessageDlg('Ripple', 'Please wait for the current operation to finish so wtrd can be restored.',
      mtInformation, [mbOK], 0);
end;

procedure TFormMain.BeginOperation(Operation: TRippleOperation);
var Item: TRippleItem;
begin
  if FWorker <> nil then Exit;
  Item := Default(TRippleItem);
  if FList.Selected <> nil then Item := FItems[FList.Selected.Index];
  FOperation := Operation;
  FWorker := TRippleWorker.Create(Operation, Item);
  FStatus.Caption := 'Working…';
  FProgress.Position := 0;
  FWorker.Start;
  FTimer.Enabled := True;
  UpdateButtons;
end;

procedure TFormMain.RefreshClick(Sender: TObject);
begin
  case FMode.ItemIndex of
    0: BeginOperation(roWatchfaces);
    1: BeginOperation(roApps);
    2: BeginOperation(roInstalled);
  end;
end;

procedure TFormMain.ModeChanged(Sender: TObject);
begin
  FList.Items.Clear;
  FItems := nil;
  FDetails.Clear;
  RefreshClick(Sender);
end;

procedure TFormMain.DetectClick(Sender: TObject);
begin BeginOperation(roIdentify); end;

procedure TFormMain.InstallClick(Sender: TObject);
begin
  if FList.Selected = nil then Exit;
  if MessageDlg('Install on watch', 'Install ' + FItems[FList.Selected.Index].Title +
    '? Notifications pause temporarily during watch access, then resume if wtrd was running. Phone-side JavaScript and configuration pages are not supported.',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then BeginOperation(roInstall);
end;

procedure TFormMain.RemoveClick(Sender: TObject);
begin
  if FList.Selected = nil then Exit;
  if MessageDlg('Remove from watch', 'Remove ' + FItems[FList.Selected.Index].Title + '?',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then BeginOperation(roRemove);
end;

procedure TFormMain.UpdateButtons;
var Idle, HasItem: Boolean;
begin
  Idle := FWorker = nil;
  HasItem := FList.Selected <> nil;
  FMode.Enabled := Idle;
  FRefresh.Enabled := Idle;
  FDetect.Enabled := Idle;
  FList.Enabled := Idle;
  FInstall.Enabled := Idle and HasItem and (FMode.ItemIndex <> 2);
  if FInstall.Enabled then FInstall.Enabled := FItems[FList.Selected.Index].DownloadURL <> '';
  FRemove.Enabled := Idle and HasItem and (FMode.ItemIndex = 2);
end;

procedure TFormMain.Selected(Sender: TObject; Item: TListItem; IsSelected: Boolean);
var A: TRippleItem;
begin
  if IsSelected and (Item.Index >= 0) and (Item.Index < Length(FItems)) then
  begin
    A := FItems[Item.Index];
    FDetails.Text := A.Title + ' — ' + A.Author + LineEnding + A.Description +
      LineEnding + A.UUID;
  end;
  UpdateButtons;
end;

procedure TFormMain.FillList;
var I: Integer; Item: TListItem;
begin
  FDetails.Clear;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to High(FItems) do
    begin
      Item := FList.Items.Add;
      Item.Caption := FItems[I].Title;
      Item.SubItems.Add(FItems[I].Author);
      Item.SubItems.Add(FItems[I].Version);
    end;
  finally FList.Items.EndUpdate; end;
end;

procedure TFormMain.Tick(Sender: TObject);
var Done: Boolean; StatusText, ErrorText: string; Percent: Integer;
begin
  if FWorker = nil then Exit;
  FWorker.Snapshot(Done, StatusText, Percent);
  FStatus.Caption := StatusText;
  FProgress.Position := Percent;
  if not Done then Exit;
  FTimer.Enabled := False;
  FWorker.WaitFor;
  ErrorText := FWorker.ErrorText;
  if ErrorText = '' then
  begin
    if FOperation <> roIdentify then
    begin
      if FOperation in [roInstall, roRemove] then FMode.ItemIndex := 2;
      FItems := FWorker.Items;
      FillList;
    end;
    FStatus.Caption := FWorker.Note;
    FProgress.Position := 100;
  end
  else FStatus.Caption := ErrorText;
  FreeAndNil(FWorker);
  UpdateButtons;
  if ErrorText <> '' then MessageDlg('Ripple', ErrorText, mtError, [mbOK], 0);
end;

end.
