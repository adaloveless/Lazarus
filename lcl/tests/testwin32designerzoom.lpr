program TestWin32DesignerZoom;

{$mode objfpc}{$H+}

// Run on Windows: lazbuild --ws=win32 testwin32designerzoom.lpi
// Exercises real HWNDs and synchronous window messages, not mocked geometry.
uses
  Interfaces, Classes, SysUtils, Types, Math, Forms, Controls, StdCtrls, ExtCtrls,
  Buttons, Graphics, LCLIntf, LCLType, Win32Proc, Windows, uDarkStyleParams;

type
  TPaintSurface = class(TCustomControl)
  protected
    procedure Paint; override;
  end;

  TTestForm = class(TForm)
  public
    procedure DesignMode;
  end;

  TObserver = class
    Changes: Integer;
    procedure BoundsChanged(Sender: TObject);
  end;

procedure TTestForm.DesignMode;
begin
  SetDesigning(True);
end;

procedure TPaintSurface.Paint;
begin
  Canvas.Brush.Color := $00332211;
  Canvas.FillRect(ClientRect);
end;

procedure TObserver.BoundsChanged(Sender: TObject);
begin
  Inc(Changes);
end;

procedure Check(Condition: Boolean; const Detail: string);
begin
  if not Condition then raise Exception.Create(Detail);
end;

function Serialize(Component: TComponent): RawByteString;
var
  Stream: TMemoryStream;
begin
  Stream := TMemoryStream.Create;
  try
    Stream.WriteComponent(Component);
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Move(Stream.Memory^, Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure SaveDiagnostic(const Data: RawByteString; const FileName: string);
var
  Binary, TextStream: TMemoryStream;
begin
  Binary := TMemoryStream.Create;
  TextStream := TMemoryStream.Create;
  try
    Binary.WriteBuffer(Data[1], Length(Data));
    Binary.Position := 0;
    ObjectBinaryToText(Binary, TextStream);
    TextStream.SaveToFile(GetTempDir + FileName);
  finally
    TextStream.Free;
    Binary.Free;
  end;
end;

var
  Host: TForm;
  Design: TTestForm;
  Container, Panel, CheckRow: TPanel;
  Checks: array[0..5] of TCheckBox;
  Button: TButton;
  LabelControl: TLabel;
  Shape: TShape;
  SpeedButton: TSpeedButton;
  Group: TGroupBox;
  Edit: TEdit;
  Combo: TComboBox;
  Surface: TPaintSurface;
  Memo: TMemo;
  PixelDC: HDC;
  PixelColor: DWORD;
  Observer: TObserver;
  Original: RawByteString;
  HostBounds: TRect;
  NativeRect: TRect;
  P, Q: TPoint;
  Width, Height, X, Y, I, J, K: Integer;
  Scale: Double;
  OldHandle: HWND;
const
  Scales: array[0..10] of Double = (1.25, 0.5, 0.9, 1.1, 0.333333, 2, 0.25, 0.1, 4, 0.99999, 1);
begin
  try
    PreferredAppMode := pamForceDark;
    Application.Initialize;
    Application.ShowMainForm := False;
    Observer := TObserver.Create;
    Host := TForm.CreateNew(nil);
    try
      Host.SetBounds(100, 100, 900, 700);
      Container := TPanel.Create(Host);
      Container.Parent := Host;
      Container.BevelOuter := bvNone;
      Container.SetBounds(0, 0, 850, 650);
      Design := TTestForm.CreateNew(Host);
      Design.Name := 'DesignedForm';
      Design.Parent := Container;
      Design.SetBounds(11, 13, 601, 401);
      Design.Constraints.MinWidth := 500;
      Design.Constraints.MinHeight := 200;
      Panel := TPanel.Create(Design);
      Panel.Name := 'Panel';
      Panel.Parent := Design;
      Panel.SetBounds(21, 23, 301, 201);
      Button := TButton.Create(Design);
      Button.Name := 'Button';
      Button.Parent := Panel;
      Button.SetBounds(31, 33, 101, 41);
      Button.Caption := 'Native control';
      LabelControl := TLabel.Create(Design);
      LabelControl.Name := 'Label';
      LabelControl.Parent := Design;
      LabelControl.SetBounds(351, 33, 101, 21);
      LabelControl.Caption := 'Graphic control';
      Shape := TShape.Create(Design);
      Shape.Name := 'Shape';
      Shape.Parent := Design;
      Shape.SetBounds(351, 63, 101, 41);
      SpeedButton := TSpeedButton.Create(Design);
      SpeedButton.Name := 'SpeedButton';
      SpeedButton.Parent := Design;
      SpeedButton.SetBounds(351, 123, 101, 41);
      SpeedButton.Caption := 'Graphic button';
      Group := TGroupBox.Create(Design);
      Group.Name := 'Group';
      Group.Parent := Design;
      Group.SetBounds(21, 251, 301, 121);
      Group.Caption := 'Native group';
      Edit := TEdit.Create(Design);
      Edit.Name := 'Edit';
      Edit.Parent := Group;
      Edit.SetBounds(11, 21, 101, 23);
      Combo := TComboBox.Create(Design);
      Combo.Name := 'Combo';
      Combo.Parent := Group;
      Combo.SetBounds(11, 61, 151, 23);
      Combo.Items.Add('Native combo');
      Combo.ItemIndex := 0;
      Surface := TPaintSurface.Create(Design);
      Surface.Name := 'BufferedSurface';
      Surface.Parent := Design;
      Surface.SetBounds(350, 200, 201, 151);
      Surface.DoubleBuffered := True;
      Memo := TMemo.Create(Design);
      Memo.Name := 'memState';
      Memo.Parent := Surface;
      Memo.SetBounds(71, 51, 91, 61);
      Memo.Lines.Text := 'memState';
      // FormDecks has a bottom row of aligned, margin-separated checkboxes.
      // Dark-theme painting must not continually undo their scaled placement.
      CheckRow := TPanel.Create(Design);
      CheckRow.Name := 'CheckRow';
      CheckRow.Parent := Design;
      CheckRow.Height := 41;
      CheckRow.Align := alBottom;
      for K := Low(Checks) to High(Checks) do
      begin
        Checks[K] := TCheckBox.Create(Design);
        Checks[K].Name := 'Check' + IntToStr(K);
        Checks[K].Parent := CheckRow;
        Checks[K].Caption := 'Hide Singers ' + IntToStr(K);
        Checks[K].Width := 155 + K * 7;
        Checks[K].AlignWithMargins := True;
        Checks[K].Margins.Left := 15;
        Checks[K].Margins.Right := 15;
        Checks[K].Align := alLeft;
      end;
      Design.DesignMode;
      Host.Show;
      Design.Show;
      Application.ProcessMessages;
      Check(Windows.GetProp(Checks[0].Handle, 'LazDarkCheckRadioOldProc') <> 0,
        'dark checkbox subclass was not installed');
      Design.OnChangeBounds := @Observer.BoundsChanged;
      Panel.OnChangeBounds := @Observer.BoundsChanged;
      Button.OnChangeBounds := @Observer.BoundsChanged;
      for K := Low(Checks) to High(Checks) do
        Checks[K].OnChangeBounds := @Observer.BoundsChanged;
      Original := Serialize(Design);
      HostBounds := Host.BoundsRect;
      Observer.Changes := 0;
      for J := 1 to 3 do
        for I := Low(Scales) to High(Scales) do
        begin
          Check(SetWindowContentScale(Container.Handle, Scales[I]), 'scale rejected');
          for K := Low(Checks) to High(Checks) do
          begin
            Windows.SendMessage(Checks[K].Handle, WM_APP + 806, 0, 0);
            Checks[K].Repaint;
            Windows.GetWindowRect(Checks[K].Handle, NativeRect);
            Scale := GetWindowEffectiveScale(Checks[K].Handle);
            Check(NativeRect.Width = Round(Checks[K].Width * Scale),
              'dark checkbox paint undid scaled width');
          end;
          Application.ProcessMessages;
          // Buffer allocation and presentation must cover the *native* client,
          // including pixels beyond logical Width/Height when zoom exceeds 100%.
          if (Scales[I] >= 0.5) and (Scales[I] <= 1.25) then
          begin
            Surface.Repaint;
            Windows.GetClientRect(Surface.Handle, NativeRect);
            PixelDC := Windows.GetDC(Surface.Handle);
            try
              PixelColor := Windows.GetPixel(PixelDC, NativeRect.Right - 4,
                NativeRect.Bottom - 4);
            finally
              Windows.ReleaseDC(Surface.Handle, PixelDC);
            end;
            Check(PixelColor = $00332211,
              'buffered paint missed client edge at ' + FloatToStr(Scales[I]) +
              ': ' + IntToHex(PixelColor, 8));
            end;
          // The IDE invalidates these caches before saving/design operations.
          Design.InvalidateClientRectCache(True);
          if Serialize(Design) <> Original then
          begin
            SaveDiagnostic(Original, 'designerzoom-before.lfm');
            SaveDiagnostic(Serialize(Design), 'designerzoom-after.lfm');
            Check(False, 'zoom changed serialized form at ' + FloatToStr(Scales[I]) +
              '; diagnostic .lfm files in ' + GetTempDir);
          end;
          Check(EqualRect(Host.BoundsRect, HostBounds), 'zoom changed host IDE window');
          Check(Observer.Changes = 0, 'zoom notified design bounds change');
          // Reapplying wheel/Fit values must do nothing after fixed-point rounding.
          Check(SetWindowContentScale(Container.Handle, Scales[I]), 'repeat rejected');
          Check(Serialize(Design) = Original, 'repeat changed serialized form');
          Scale := GetWindowEffectiveScale(Button.Handle);
          Windows.GetWindowRect(Button.Handle, NativeRect);
          Check(NativeRect.Width = Round(101 * Scale), 'wrong native button width');
          Check(NativeRect.Height = Round(41 * Scale), 'wrong native button height');
          GetWindowSize(Button.Handle, Width, Height);
          Check((Width = 101) and (Height = 41), 'lossy logical button size');
          GetWindowRelativePosition(Button.Handle, X, Y);
          Check((X = 31) and (Y = 33), 'lossy logical button position');
          P := Button.ClientToScreen(Types.Point(40, 20));
          Q := Button.ScreenToClient(P);
          Check((Abs(Q.X - 40) <= Ceil(1 / Scale)) and
            (Abs(Q.Y - 20) <= Ceil(1 / Scale)), 'coordinate round trip');
        end;
      Design.SetBounds(11, 13, 2401, 1601);
      Check(SetWindowContentScale(Container.Handle, 4), 'large scale rejected');
      Windows.GetClientRect(Design.Handle, NativeRect);
      Check((NativeRect.Width = 9604) and (NativeRect.Height = 6404),
        'native tracking limits clamped a view larger than the monitor');
      Check(SetWindowContentScale(Container.Handle, 1), 'large scale reset rejected');
      Design.SetBounds(11, 13, 601, 401);
      Check(SetWindowContentScale(Container.Handle, 0.5), 'resize scale rejected');
      Button.SetBounds(111, 113, 121, 61);
      // RealizeWinControlBounds in the designer also calls this API directly.
      LCLIntf.SetWindowPos(Button.Handle, 0, Button.Left, Button.Top,
        Button.Width, Button.Height, SWP_NOZORDER or SWP_NOACTIVATE);
      Application.ProcessMessages;
      Check((Button.Left = 111) and (Button.Top = 113) and
        (Button.Width = 121) and (Button.Height = 61), 'editing zoomed control changed bounds');
      Design.SetBounds(19, 27, 641, 441);
      Application.ProcessMessages;
      Check((Design.Left = 19) and (Design.Top = 27) and
        (Design.Width = 641) and (Design.Height = 441), 'editing zoomed form changed bounds');
      Check(SetWindowContentScale(Container.Handle, 1), 'reset rejected');
      Application.ProcessMessages;
      Check((Button.Left = 111) and (Button.Top = 113) and
        (Button.Width = 121) and (Button.Height = 61), 'reset lost edit');
      Check(SetWindowContentScale(Container.Handle, 0.5), 'cleanup scale rejected');
      OldHandle := Container.Handle;
      Container.Free;
      Check(not Windows.IsWindow(OldHandle), 'container not destroyed');
      Check(GetWindowEffectiveScale(Host.Handle) = 1, 'scale escaped subtree');
      Check(not SetWindowContentScale(0, 0.5), 'invalid window accepted');
      Check(not SetWindowContentScale(Host.Handle, 0), 'zero scale accepted');
      WriteLn('PASS: repeated zoom, serialized bounds, native geometry, coordinates, edits, cleanup');
    finally
      Host.Free;
      Observer.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.Message);
      Halt(1);
    end;
  end;
end.
