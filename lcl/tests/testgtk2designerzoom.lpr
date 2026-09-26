program TestGtk2DesignerZoom;

{$mode objfpc}{$H+}

// Run on Linux: lazbuild --ws=gtk2 testgtk2designerzoom.lpi
uses
  Interfaces, Classes, SysUtils, Types, Math, Forms, Controls, StdCtrls,
  ExtCtrls, Graphics, LCLIntf, LCLType, Gtk2, Gdk2, Gtk2Proc;

type
  TPaintSurface = class(TCustomControl)
  public
    LastClip: TRect;
  protected
    procedure Paint; override;
  end;

procedure TPaintSurface.Paint;
begin
  GetClipBox(Canvas.Handle, @LastClip);
  Canvas.Brush.Color := $00332211;
  Canvas.FillRect(ClientRect);
end;

procedure Check(AValue: Boolean; const ADetail: string);
begin
  if not AValue then Raise Exception.Create(ADetail);
end;

function Serialize(AComponent: TComponent): RawByteString;
var
  Stream: TMemoryStream;
begin
  Stream := TMemoryStream.Create;
  try
    Stream.WriteComponent(AComponent);
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Move(Stream.Memory^, Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure SaveText(const Data: RawByteString; const AFileName: string);
var
  Input, Output: TMemoryStream;
begin
  Input := TMemoryStream.Create;
  Output := TMemoryStream.Create;
  try
    Input.WriteBuffer(Data[1], Length(Data));
    Input.Position := 0;
    ObjectBinaryToText(Input, Output);
    Output.SaveToFile(AFileName);
  finally
    Output.Free;
    Input.Free;
  end;
end;

var
  Host, Design: TForm;
  Container, Panel: TPanel;
  Button: TButton;
  Surface: TPaintSurface;
  Original: RawByteString;
  P, Q: TPoint;
  PaintRect: TRect;
  W, H, X, Y, I: Integer;
  NativeW, NativeH: Integer;
  Scale: Double;
const
  Scales: array[0..7] of Double = (0.5, 1.25, 0.9, 2, 0.25, 4, 0.99999, 1);
begin
  try
    Application.Initialize;
    Application.ShowMainForm := False;
    Host := TForm.CreateNew(nil);
    try
      Host.SetBounds(100, 100, 900, 700);
      Container := TPanel.Create(Host);
      Container.Parent := Host;
      Container.BevelOuter := bvNone;
      Container.SetBounds(0, 0, 850, 650);
      Design := TForm.CreateNew(Host);
      Design.Name := 'DesignedForm';
      Design.Parent := Container;
      Design.SetBounds(11, 13, 601, 401);
      Panel := TPanel.Create(Design);
      Panel.Name := 'Panel';
      Panel.Parent := Design;
      Panel.BevelOuter := bvNone;
      Panel.SetBounds(21, 23, 301, 201);
      Button := TButton.Create(Design);
      Button.Name := 'Button';
      Button.Parent := Panel;
      Button.SetBounds(31, 33, 101, 41);
      Button.Caption := 'Native control';
      Surface := TPaintSurface.Create(Design);
      Surface.Name := 'Surface';
      Surface.Parent := Design;
      Surface.SetBounds(350, 200, 201, 151);
      Surface.DoubleBuffered := True;
      Host.Show;
      Design.Show;
      Application.ProcessMessages;
      Application.ProcessMessages;
      Design.InvalidateClientRectCache(True);
      Original := Serialize(Design);
      for I := Low(Scales) to High(Scales) do
      begin
        Check(SetWindowContentScale(Container.Handle, Scales[I]), 'scale rejected');
        Application.ProcessMessages;
        if Serialize(Design) <> Original then
        begin
          SaveText(Original, '/tmp/gtkzoom-before.lfm');
          SaveText(Serialize(Design), '/tmp/gtkzoom-after.lfm');
          Check(False, 'zoom changed serialized form');
        end;
        Scale := GetWindowEffectiveScale(Button.Handle);
        Check(Abs(Scale - Scales[I]) < 1 / 65536, 'wrong effective scale');
        Check(PGtkWidget(Button.Handle)^.allocation.width = Round(101 * Scale),
          'wrong native button width');
        Check(PGtkWidget(Button.Handle)^.allocation.height = Round(41 * Scale),
          'wrong native button height');
        GetWindowSize(Button.Handle, W, H);
        Check((W = 101) and (H = 41), 'lossy logical size');
        GetWindowRelativePosition(Button.Handle, X, Y);
        Check((X = 31) and (Y = 33), 'lossy logical position');
        P := Button.ClientToScreen(Point(40, 20));
        Q := Button.ScreenToClient(P);
        Check((Abs(Q.X - 40) <= Ceil(1 / Scale)) and
          (Abs(Q.Y - 20) <= Ceil(1 / Scale)), 'coordinate round trip');
        if (Scale >= 0.5) and (Scale <= 1.25) then
        begin
          Check(PGtkWidget(GetFixedWidget(PGtkWidget(Surface.Handle)))^.allocation.width =
            Round(Surface.ClientWidth * Scale),
            'scaled client widget has wrong native width: ' +
            IntToStr(PGtkWidget(GetFixedWidget(PGtkWidget(Surface.Handle)))^.allocation.width));
          gdk_window_get_size(GetControlWindow(PGtkWidget(GetFixedWidget(
            PGtkWidget(Surface.Handle)))), @NativeW, @NativeH);
          Check(NativeW = Round(Surface.ClientWidth * Scale),
            'scaled client window has wrong native width: ' + IntToStr(NativeW));
          PaintRect := Rect(0, 0, Surface.ClientWidth, Surface.ClientHeight);
          Surface.LastClip := Rect(0, 0, 0, 0);
          LCLIntf.InvalidateRect(Surface.Handle, @PaintRect, False);
          Application.ProcessMessages;
          Check((Surface.LastClip.Right >= Surface.ClientWidth - 1) and
            (Surface.LastClip.Bottom >= Surface.ClientHeight - 1),
            'scaled logical paint clip missed client edge at ' +
            FloatToStr(Scale) + ': ' + IntToStr(Surface.LastClip.Right) + 'x' +
            IntToStr(Surface.LastClip.Bottom));
        end;
      end;
      Check(SetWindowContentScale(Container.Handle, 0.5), 'edit scale rejected');
      Button.SetBounds(111, 113, 121, 61);
      LCLIntf.SetWindowPos(Button.Handle, 0, Button.Left, Button.Top,
        Button.Width, Button.Height, SWP_NOZORDER or SWP_NOACTIVATE);
      Application.ProcessMessages;
      Check((Button.Left = 111) and (Button.Top = 113) and
        (Button.Width = 121) and (Button.Height = 61), 'zoomed edit changed bounds');
      Check(SetWindowContentScale(Container.Handle, 1), 'reset rejected');
      Check(not SetWindowContentScale(0, 0.5), 'invalid handle accepted');
      Check(not SetWindowContentScale(Host.Handle, 0), 'invalid scale accepted');
      WriteLn('PASS: GTK2 designer zoom geometry, serialization, coordinates, edits');
    finally
      Host.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.Message);
      Halt(1);
    end;
  end;
end.
