{
 *****************************************************************************
  See the file COPYING.modifiedLGPL.txt, included in this distribution,
  for details about the license.
 *****************************************************************************

 Authors: Maciej Izak
          Michael W. Vogel

 The Resizer is a visual control that own two ScrollBars and the ResizeControl
 that shows the design form, and the zoom bar below them.

 Zoom: the design form keeps its real bounds; the widgetset draws the form
 container scaled (LCLIntf.SetWindowContentScale), so everything here that
 converts between form size and on-screen size multiplies by the zoom.
}

unit DockedResizer;

{$mode objfpc}{$H+}
{ $define DEBUGDOCKEDFORMEDITOR}

interface

uses
  // RTL, FCL
  Classes, SysUtils, Types, Math,
  // LCL
  LCLType, Controls, ExtCtrls, Forms, StdCtrls, Buttons, Dialogs, LCLIntf, Graphics,
  LCLProc,
  // DockedFormEditor
  DockedResizeControl, DockedDesignForm, DockedStrConsts;

type

  { TResizer }

  TResizer = class(TPanel)
  private const
    ZoomMin = 0.1;
    ZoomMax = 4.0;
    ZoomLevels: array[0..13] of Double =
      (0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0);
  private
    FDesignScroll: array[0..1] of Boolean;
    FDesignForm: TDesignForm;
    FPostponedAdjustResizeControl: Boolean;
    // To perform proper behaviour for scroolbar with "PageSize" we need to remember real
    // maximal values (is possible to scroll outside of range 0..(Max - PageSize),
    // after mouse click in button responsible for changing value of scrollbar,
    // our value is equal to Max :\). Workaround: we need to remember real max value in our own place
    FRealMaxH: Integer;
    FRealMaxV: Integer;
    FResizeControl: TResizeControl;
    FScrollBarHorz: TScrollBar;
    FScrollBarVert: TScrollBar;
    FScrollPos: TPoint;
    FZoomBar: TPanel;
    FZoomCombo: TComboBox;
    FZoomFitButton: TSpeedButton;
    FZoomInButton: TSpeedButton;
    FZoomLabel: TLabel;
    FZoomOutButton: TSpeedButton;
    FZoomResetButton: TSpeedButton;
    FZoomUnsupported: Boolean;
    procedure CreateZoomBar;
    procedure DesignerKeyDown({%H-}Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DesignMouseWheel({%H-}Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; {%H-}MousePos: TPoint; var Handled: Boolean);
    function  FitZoom: Double;
    procedure FormResized(Sender: TObject);
    function  GetZoom: Double;
    procedure ScrollTo(AScrollBar: TScrollBar; APos: Integer);
    procedure UpdateZoomBar;
    procedure ZoomComboEditingDone({%H-}Sender: TObject);
    procedure ZoomComboSelect({%H-}Sender: TObject);
    procedure ZoomFromText(const AText: String);
    procedure ZoomButtonClick(Sender: TObject);
    function  ZoomStep(AZoom: Double; AUp: Boolean): Double;
    function GetFormContainer: TWinControl;
    procedure ScrollBarHorzMouseWheel(Sender: TObject; {%H-}Shift: TShiftState;
      WheelDelta: Integer; {%H-}MousePos: TPoint; var {%H-}Handled: Boolean);
    procedure ScrollBarVertMouseWheel(Sender: TObject; {%H-}Shift: TShiftState;
      WheelDelta: Integer; {%H-}MousePos: TPoint; var {%H-}Handled: Boolean);
    procedure SetDesignForm(AValue: TDesignForm);
    procedure SetDesignScroll(AIndex: Integer; AValue: Boolean);
    procedure ScrollBarScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: Integer);
  public
    constructor Create(TheOwner: TWinControl); reintroduce;
    destructor Destroy; override;
    procedure AdjustResizer(Sender: TObject);
    procedure DesignerSetFocus;
    // zoom the design form; AFit: keep it fitting the page. The form point
    // under AAnchor (ResizeControl client coordinates) stays where it is.
    procedure SetZoom(AZoom: Double; AFit: Boolean; const AAnchor: TPoint); overload;
    procedure SetZoom(AZoom: Double; AFit: Boolean = False); overload;
  public
    property DesignForm: TDesignForm read FDesignForm write SetDesignForm;
    property DesignScrollRight: Boolean index SB_Vert read FDesignScroll[SB_Vert] write SetDesignScroll;
    property DesignScrollBottom: Boolean index SB_Horz read FDesignScroll[SB_Horz] write SetDesignScroll;
    property FormContainer: TWinControl read GetFormContainer;
    property ResizeControl: TResizeControl read FResizeControl;
    property Zoom: Double read GetZoom;
  end;

implementation

{ TResizer }

procedure TResizer.CreateZoomBar;

  function NewButton(const ACaption, AHint: String; ALeftOf: TControl): TSpeedButton;
  begin
    Result := TSpeedButton.Create(FZoomBar);
    Result.Caption := ACaption;
    Result.Hint := AHint;
    Result.ShowHint := True;
    Result.Flat := True;
    Result.AutoSize := True;
    Result.Constraints.MinWidth := ScaleX(22, 96);
    Result.OnClick := @ZoomButtonClick;
    Result.AnchorSideLeft.Control := ALeftOf;
    Result.AnchorSideLeft.Side := asrRight;
    Result.BorderSpacing.Left := ScaleX(2, 96);
    Result.AnchorSideTop.Control := FZoomCombo;
    Result.AnchorSideBottom.Control := FZoomCombo;
    Result.AnchorSideBottom.Side := asrBottom;
    Result.Anchors := [akLeft, akTop, akBottom];
    Result.Parent := FZoomBar;
  end;

var
  i: Integer;
begin
  FZoomBar := TPanel.Create(Self);
  FZoomBar.BevelOuter := bvNone;
  FZoomBar.Caption := '';
  FZoomBar.AutoSize := True;
  FZoomBar.Align := alBottom;
  FZoomBar.Parent := Self;

  FZoomLabel := TLabel.Create(FZoomBar);
  FZoomLabel.Caption := SZoomCaption;
  FZoomLabel.AnchorSideLeft.Control := FZoomBar;
  FZoomLabel.BorderSpacing.Left := ScaleX(6, 96);
  FZoomLabel.Parent := FZoomBar;

  FZoomCombo := TComboBox.Create(FZoomBar);
  FZoomCombo.Hint := SZoomComboHint;
  FZoomCombo.ShowHint := True;
  for i := Low(ZoomLevels) to High(ZoomLevels) do
    FZoomCombo.Items.Add(IntToStr(Round(ZoomLevels[i] * 100)) + '%');
  FZoomCombo.Width := ScaleX(76, 96);
  FZoomCombo.BorderSpacing.Around := ScaleX(2, 96);
  FZoomCombo.OnSelect := @ZoomComboSelect;
  FZoomCombo.OnEditingDone := @ZoomComboEditingDone;
  FZoomCombo.AnchorSideLeft.Control := FZoomLabel;
  FZoomCombo.AnchorSideLeft.Side := asrRight;
  FZoomCombo.AnchorSideTop.Control := FZoomBar;
  FZoomCombo.Parent := FZoomBar;

  FZoomOutButton := NewButton('-', SZoomOutHint, FZoomLabel);
  FZoomCombo.AnchorSideLeft.Control := FZoomOutButton;
  FZoomInButton := NewButton('+', SZoomInHint, FZoomCombo);
  FZoomResetButton := NewButton('100%', SZoomResetHint, FZoomInButton);
  FZoomFitButton := NewButton(SZoomFit, SZoomFitHint, FZoomResetButton);
  FZoomFitButton.GroupIndex := 1;
  FZoomFitButton.AllowAllUp := True;

  FZoomLabel.AnchorVerticalCenterTo(FZoomCombo);
  UpdateZoomBar;
end;

procedure TResizer.DesignerKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  // Ctrl on Windows/Linux, Cmd on macOS; Alt combinations are not ours
  if (Shift * [ssCtrl, ssMeta] = []) or (ssAlt in Shift) then Exit;
  case Key of
    VK_OEM_PLUS, VK_ADD:       SetZoom(ZoomStep(Zoom, True));
    VK_OEM_MINUS, VK_SUBTRACT: SetZoom(ZoomStep(Zoom, False));
    VK_0, VK_NUMPAD0:          SetZoom(1.0);
  else
    Exit;
  end;
  Key := 0;
end;

procedure TResizer.DesignMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  LAnchor: TPoint;
begin
  if not Assigned(FDesignForm) or (WheelDelta = 0) then Exit;
  if (ssCtrl in Shift) or (ssMeta in Shift) then
  begin
    // zoom around the mouse cursor
    LAnchor := ResizeControl.ScreenToClient(Mouse.CursorPos);
    SetZoom(Zoom * Power(1.1, WheelDelta / 120), False, LAnchor);
    Handled := True;
  end
  else if ssShift in Shift then
  begin
    if not FScrollBarHorz.Visible then Exit;
    ScrollTo(FScrollBarHorz, FScrollPos.x - WheelDelta);
    Handled := True;
  end
  else
  begin
    // a form larger than the page scrolls with the wheel
    if not FScrollBarVert.Visible then Exit;
    ScrollTo(FScrollBarVert, FScrollPos.y - WheelDelta);
    Handled := True;
  end;
end;

function TResizer.FitZoom: Double;
var
  LAvailWidth, LAvailHeight: Integer;
begin
  Result := 1.0;
  if not Assigned(FDesignForm) then Exit;
  // the page without scrollbars: a fitting form needs none
  LAvailWidth  := ClientWidth - 2 * ResizeControl.SizerGripSize - 1;
  LAvailHeight := ClientHeight - 2 * ResizeControl.SizerGripSize - ResizeControl.FakeMenu.Height - 1;
  if FZoomBar.Visible then
    Dec(LAvailHeight, FZoomBar.Height);
  if (FDesignForm.Width > 0) and (LAvailWidth < FDesignForm.Width) then
    Result := LAvailWidth / FDesignForm.Width;
  if (FDesignForm.Height > 0) and (LAvailHeight < FDesignForm.Height * Result) then
    Result := LAvailHeight / FDesignForm.Height;
  // floor to 0.1%, so rounding never makes the fitted form a pixel too big
  Result := EnsureRange(Floor(Result * 1000) / 1000, ZoomMin, 1.0);
end;

function TResizer.GetZoom: Double;
begin
  if Assigned(FDesignForm) then
    Result := FDesignForm.Zoom
  else
    Result := 1.0;
end;

procedure TResizer.ScrollTo(AScrollBar: TScrollBar; APos: Integer);
begin
  AScrollBar.Position := APos;
  ScrollBarScroll(AScrollBar, scEndScroll, APos);
end;

procedure TResizer.SetZoom(AZoom: Double; AFit: Boolean; const AAnchor: TPoint);
var
  LOldZoom: Double;
  LFormPos: TPointF;
  LOffsetY: Integer;
begin
  if not Assigned(FDesignForm) or FZoomUnsupported then Exit;
  if AFit then
    AZoom := FitZoom;
  AZoom := EnsureRange(AZoom, ZoomMin, ZoomMax);
  // snap near 100%, so wheel zooming can get back to exactly actual size
  if Abs(AZoom - 1.0) < 0.02 then
    AZoom := 1.0;
  LOldZoom := FDesignForm.Zoom;
  FDesignForm.ZoomFit := AFit;
  if AZoom = LOldZoom then
  begin
    UpdateZoomBar;
    Exit;
  end;

  // the form point under the anchor, in form coordinates
  LOffsetY := ResizeControl.SizerGripSize + ResizeControl.FakeMenu.Height;
  LFormPos.X := (AAnchor.X + FScrollPos.x - ResizeControl.SizerGripSize) / LOldZoom;
  LFormPos.Y := (AAnchor.Y + FScrollPos.y - LOffsetY) / LOldZoom;

  FDesignForm.Zoom := AZoom;
  AdjustResizer(nil);
  if FDesignForm.Zoom <> AZoom then
  begin
    // the widgetset cannot scale: back to the unzoomed layout, zoom off
    FZoomUnsupported := True;
    FDesignForm.Zoom := 1.0;
    FDesignForm.ZoomFit := False;
    AdjustResizer(nil);
    UpdateZoomBar;
    Exit;
  end;

  // keep that point under the anchor
  if FScrollBarHorz.Visible then
    ScrollTo(FScrollBarHorz, Round(LFormPos.X * AZoom) + ResizeControl.SizerGripSize - AAnchor.X);
  if FScrollBarVert.Visible then
    ScrollTo(FScrollBarVert, Round(LFormPos.Y * AZoom) + LOffsetY - AAnchor.Y);
  UpdateZoomBar;
  DesignForm.Form.Invalidate;
  ResizeControl.Invalidate;
end;

procedure TResizer.SetZoom(AZoom: Double; AFit: Boolean);
begin
  // anchor: the middle of the visible design area
  SetZoom(AZoom, AFit, Point(ResizeControl.ClientWidth div 2, ResizeControl.ClientHeight div 2));
end;

procedure TResizer.UpdateZoomBar;
var
  LText: String;
begin
  if not Assigned(FZoomBar) then Exit;
  LText := IntToStr(Round(Zoom * 100)) + '%';
  if FZoomCombo.Text <> LText then
    FZoomCombo.Text := LText;
  FZoomFitButton.Down := Assigned(FDesignForm) and FDesignForm.ZoomFit;
  if FZoomUnsupported then
  begin
    FZoomBar.Enabled := False;
    FZoomLabel.Hint := SZoomUnsupported;
    FZoomLabel.ShowHint := True;
    FZoomCombo.Hint := SZoomUnsupported;
  end;
end;

procedure TResizer.ZoomComboEditingDone(Sender: TObject);
begin
  // no DesignerSetFocus: EditingDone also comes when the user clicks away
  ZoomFromText(FZoomCombo.Text);
end;

procedure TResizer.ZoomComboSelect(Sender: TObject);
begin
  if FZoomCombo.ItemIndex >= 0 then
    ZoomFromText(FZoomCombo.Items[FZoomCombo.ItemIndex]);
  DesignerSetFocus;
end;

procedure TResizer.ZoomFromText(const AText: String);
var
  LPercent: Double;
begin
  if TryStrToFloat(Trim(StringReplace(AText, '%', '', [rfReplaceAll])), LPercent)
  and (LPercent > 0) then
    SetZoom(LPercent / 100)
  else
    UpdateZoomBar;
end;

procedure TResizer.ZoomButtonClick(Sender: TObject);
begin
  if Sender = FZoomInButton then
    SetZoom(ZoomStep(Zoom, True))
  else if Sender = FZoomOutButton then
    SetZoom(ZoomStep(Zoom, False))
  else if Sender = FZoomResetButton then
    SetZoom(1.0)
  else if Sender = FZoomFitButton then
  begin
    if FZoomFitButton.Down then
      SetZoom(0, True)
    else
      SetZoom(1.0);
  end;
  DesignerSetFocus;
end;

function TResizer.ZoomStep(AZoom: Double; AUp: Boolean): Double;
var
  i: Integer;
begin
  // the next preset level above/below AZoom
  if AUp then
  begin
    for i := Low(ZoomLevels) to High(ZoomLevels) do
      if ZoomLevels[i] > AZoom * 1.001 then
        Exit(ZoomLevels[i]);
    Result := ZoomMax;
  end else
  begin
    for i := High(ZoomLevels) downto Low(ZoomLevels) do
      if ZoomLevels[i] < AZoom * 0.999 then
        Exit(ZoomLevels[i]);
    Result := ZoomMin;
  end;
end;

procedure TResizer.FormResized(Sender: TObject);
begin
  DesignForm.Form.Width  := ResizeControl.NewFormSize.X;
  DesignForm.Form.Height := ResizeControl.NewFormSize.Y;
  SetTimer(DesignForm.Form.Handle, WM_BOUNDTODESIGNTABSHEET, 10, nil);
end;

function TResizer.GetFormContainer: TWinControl;
begin
  Result := ResizeControl.FormContainer;
end;

procedure TResizer.ScrollBarHorzMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  LScrollPos: Integer;
begin
  LScrollPos := FScrollPos.x - WheelDelta;
  FScrollBarHorz.Position := LScrollPos;
  ScrollBarScroll(FScrollBarHorz, scEndScroll, LScrollPos);
  Handled := True;
end;

procedure TResizer.ScrollBarVertMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  LScrollPos: Integer;
begin
  LScrollPos := FScrollPos.y - WheelDelta;
  FScrollBarVert.Position := LScrollPos;
  ScrollBarScroll(FScrollBarVert, scEndScroll, LScrollPos);
  Handled := True;
end;

procedure TResizer.SetDesignForm(AValue: TDesignForm);
begin
  {$IFDEF DEBUGDOCKEDFORMEDITOR}
  if Assigned(AValue) then DebugLn('TResizer.SetDesignForm: New Designform: ', DbgSName(AValue.Form))
                      else DebugLn('TResizer.SetDesignForm: New Designform: nil');
  {$ENDIF}
  if FDesignForm <> nil then
  begin
    FDesignForm.OnChangeHackedBounds := nil;
    FDesignForm.OnDesignMouseWheel := nil;
  end;
  FDesignForm := AValue;
  if Assigned(FDesignForm) then
  begin
    FDesignForm.BeginUpdate;
    FDesignForm.Form.Parent := ResizeControl.FormContainer;
    FDesignForm.EndUpdate;
    FDesignForm.OnChangeHackedBounds := @AdjustResizer;
    FDesignForm.OnDesignMouseWheel := @DesignMouseWheel;
    if Assigned(FDesignForm.AnchorDesigner) then
      FDesignForm.AnchorDesigner.Parent := ResizeControl.AnchorContainer;
  end;
  ResizeControl.DesignForm := AValue;
  UpdateZoomBar;
end;

procedure TResizer.SetDesignScroll(AIndex: Integer; AValue: Boolean);

  procedure PerformScroll(AScroll: TScrollBar);
  begin
    AScroll.Visible  := AValue;
    AScroll.Position := 0;
  end;

begin
  if FDesignScroll[AIndex] = AValue then Exit;
  FDesignScroll[AIndex] := AValue;
  case AIndex of
    SB_Horz: PerformScroll(FScrollBarHorz);
    SB_Vert: PerformScroll(FScrollBarVert);
  else
    raise EArgumentOutOfRangeException.CreateRes(@SArgumentOutOfRange);
  end;
end;

procedure TResizer.ScrollBarScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: Integer);
var
  ADesignFormAssigned: boolean;
begin
  case ScrollCode of
    scLineDown: ScrollPos := ScrollPos + 50;
    scLineUp:   ScrollPos := ScrollPos - 50;
    scPageDown:
      begin
        if Sender = FScrollBarHorz then ScrollPos := ScrollPos + ResizeControl.Width;
        if Sender = FScrollBarVert then ScrollPos := ScrollPos + ResizeControl.Height;
      end;
    scPageUp:
      begin
        if Sender = FScrollBarHorz then ScrollPos := ScrollPos - ResizeControl.Width;
        if Sender = FScrollBarVert then ScrollPos := ScrollPos - ResizeControl.Height;
      end;
  end;
  ADesignFormAssigned := Assigned(FDesignForm);
  if ADesignFormAssigned then
    DesignForm.BeginUpdate;
  if Sender = FScrollBarVert then
  begin
    // Warning - don't overflow the range! (go to description for FRealMaxV)
    ScrollPos := Min(ScrollPos, FRealMaxV);
    ScrollPos := Max(ScrollPos, 0);
    FScrollPos.y := ScrollPos;
  end;
  if Sender = FScrollBarHorz then
  begin
    ScrollPos := Min(ScrollPos, FRealMaxH);
    ScrollPos := Max(ScrollPos, 0);
    FScrollPos.x := ScrollPos;
  end;
  if ADesignFormAssigned then
    DesignForm.EndUpdate;
  if not FPostponedAdjustResizeControl then
  begin
    ResizeControl.AdjustBounds(FScrollPos);
    ResizeControl.DesignerSetFocus;
  end;
  if ADesignFormAssigned then
    DesignForm.Form.Invalidate;
end;

constructor TResizer.Create(TheOwner: TWinControl);
begin
  inherited Create(TheOwner);

  BevelOuter := bvNone;
  BorderStyle := bsNone;
  Caption := '';
  Align := alClient;
  FPostponedAdjustResizeControl := False;
  FScrollPos := Point(0, 0);

  CreateZoomBar;

  FScrollBarVert := TScrollBar.Create(nil);
  FScrollBarVert.Kind := sbVertical;
  FScrollBarVert.Parent := Self;
  FScrollBarVert.AnchorSideTop.Control := Self;
  FScrollBarVert.AnchorSideRight.Control := Self;
  FScrollBarVert.AnchorSideRight.Side := asrRight;
  FScrollBarVert.AnchorSideBottom.Side := asrBottom;
  FScrollBarVert.Anchors := [akTop, akRight, akBottom];
  FScrollBarVert.Visible := False;
  FScrollBarVert.OnScroll := @ScrollBarScroll;
  FScrollBarVert.AddHandlerOnMouseWheel(@ScrollBarVertMouseWheel);

  FScrollBarHorz := TScrollBar.Create(nil);
  FScrollBarHorz.Parent := Self;
  FScrollBarHorz.AnchorSideLeft.Control := Self;
  FScrollBarHorz.AnchorSideRight.Side := asrRight;
  FScrollBarHorz.AnchorSideBottom.Control := FZoomBar;
  FScrollBarHorz.AnchorSideBottom.Side := asrTop;
  FScrollBarHorz.Anchors := [akLeft, akRight, akBottom];
  FScrollBarHorz.Visible := False;
  FScrollBarHorz.OnScroll := @ScrollBarScroll;
  FScrollBarHorz.AddHandlerOnMouseWheel(@ScrollBarHorzMouseWheel);

  FResizeControl := TResizeControl.Create(nil);
  FResizeControl.Name := '';
  FResizeControl.Parent := Self;
  FResizeControl.AnchorSideLeft.Control := Self;
  FResizeControl.AnchorSideTop.Control := Self;
  FResizeControl.AnchorSideRight.Control := FScrollBarVert;
  FResizeControl.AnchorSideBottom.Control := FScrollBarHorz;
  FResizeControl.Anchors := [akTop, akLeft, akRight, akBottom];

  FScrollBarVert.AnchorSideBottom.Control := ResizeControl;
  FScrollBarHorz.AnchorSideRight.Control := ResizeControl;

  FResizeControl.OnResized := @FormResized;
  FResizeControl.OnChangeBounds := @AdjustResizer;
  FResizeControl.OnDesignerKeyDown := @DesignerKeyDown;
  FResizeControl.OnMouseWheel := @DesignMouseWheel;
end;

destructor TResizer.Destroy;
begin
  Pointer(FDesignForm) := nil;
  FreeAndNil(FResizeControl);
  FreeAndNil(FScrollBarVert);
  FreeAndNil(FScrollBarHorz);
  inherited Destroy;
end;

procedure TResizer.AdjustResizer(Sender: TObject);
var
  LWidth, LHeight: Integer;
  LScrollPos: Integer;
begin
  if not Assigned(FDesignForm) then Exit;
  if ResizeControl.Resizing then
  begin
    DesignForm.BeginUpdate;
    DesignForm.EndUpdate;
    ResizeControl.AdjustBounds(FScrollPos);
    Exit;
  end;

  // zoom applies to the form page only (ResizeControl.Zoom), not to anchors
  FZoomBar.Visible := ResizeControl.FormClient.Visible;
  if FDesignForm.ZoomFit and not FZoomUnsupported then
    FDesignForm.Zoom := FitZoom;
  UpdateZoomBar;
  LWidth  := Round(FDesignForm.Width  * ResizeControl.Zoom) + 2 * ResizeControl.SizerGripSize;
  LHeight := Round(FDesignForm.Height * ResizeControl.Zoom) + 2 * ResizeControl.SizerGripSize + ResizeControl.FakeMenu.Height;
  {$IFDEF DEBUGDOCKEDFORMEDITOR} DebugLn('TResizer.AdjustResizer Resizer Width:', DbgS(LWidth), ' Height:', DbgS(LHeight)); {$ENDIF}

  FPostponedAdjustResizeControl := True;
  if ResizeControl.Width < LWidth then
  begin
    // if designer frame is smaller as scrollbar, show scrollbar
    DesignScrollBottom := True;
    FScrollBarHorz.Max := LWidth;
    FRealMaxH := LWidth - ResizeControl.Width;
    FScrollBarHorz.PageSize := ResizeControl.Width;
    if FScrollPos.x > FRealMaxH then
    begin
      FScrollPos.x := FRealMaxH;
      LScrollPos := FScrollPos.x;
      ScrollBarScroll(FScrollBarHorz, scEndScroll, LScrollPos);
    end;
  end else begin
    // invisible ScrollBar
    DesignScrollBottom := False;
    LScrollPos := 0;
    ScrollBarScroll(FScrollBarHorz, scEndScroll, LScrollPos);
  end;

  if ResizeControl.Height < LHeight then
  begin
    // if designer frame is higher as scrollbar, show scrollbar
    DesignScrollRight := True;
    FScrollBarVert.Max := LHeight;
    FRealMaxV := LHeight - ResizeControl.Height;
    FScrollBarVert.PageSize := ResizeControl.Height;
    if FScrollPos.y > FRealMaxV then
    begin
      FScrollPos.y := FRealMaxV;
      LScrollPos := FScrollPos.y;
      ScrollBarScroll(FScrollBarVert, scEndScroll, LScrollPos);
    end;
  end else begin
    DesignScrollRight := False;
    LScrollPos := 0;
    ScrollBarScroll(FScrollBarVert, scEndScroll, LScrollPos);
  end;
  FPostponedAdjustResizeControl := False;

  ResizeControl.AdjustBounds(FScrollPos);
  ResizeControl.ClientChangeBounds(nil);
end;

procedure TResizer.DesignerSetFocus;
begin
  ResizeControl.DesignerSetFocus;
  if Assigned(FDesignForm) and Assigned(FDesignForm.AnchorDesigner) then
    FDesignForm.AnchorDesigner.OnMouseWheel := @ScrollBarVertMouseWheel;
end;

end.

