{
  Double Commander
  -------------------------------------------------------------------------
  Windows dark style widgetset implementation

  Copyright (C) 2021-2024 Alexander Koblov (alexx2000@mail.ru)

  This library is free software; you can redistribute it and/or
  modify it under the terms of the GNU Lesser General Public
  License as published by the Free Software Foundation; either
  version 2.1 of the License, or (at your option) any later version
  with the following modification:

  As a special exception, the copyright holders of this library give you
  permission to link this library with independent modules to produce an
  executable, regardless of the license terms of these independent modules,and
  to copy and distribute the resulting executable under terms of your choice,
  provided that you also meet, for each linked independent module, the terms
  and conditions of the license of that module. An independent module is a
  module which is not derived from or based on this library. If you modify
  this library, you may extend this exception to your version of the library,
  but you are not obligated to do so. If you do not wish to do so, delete this
  exception statement from your version.

  This library is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  Lesser General Public License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with this program. If not, see <http://www.gnu.org/licenses/>.
}

unit uWin32WidgetSetDark;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Controls,
  LCLVersion, uDarkStyleParams, uDarkStyleSchemes;

procedure ApplyDarkStyle;
procedure DarkFormChanged(Form: TObject);
procedure Initialize(const CS:TDSColors);
procedure SetColorsScheme(Scheme:TDSColors);
procedure TryEnforceDarkStyleForCtrl(AWinControl: TWinControl);

implementation

uses
  Classes, SysUtils, Win32Int, WSLCLClasses, Forms, Windows, Win32Proc, Menus,
  LCLType, Win32WSComCtrls, ComCtrls, ToolWin, LMessages, Win32WSStdCtrls,
  WSStdCtrls, Win32WSControls, StdCtrls, WSControls, Graphics, Themes, LazUTF8,
  UxTheme, Win32Themes, ExtCtrls, WSMenus, JwaWinGDI, FPImage, Math, uDarkStyle,
  WSComCtrls, CommCtrl, uImport, WSForms, Win32WSButtons, WSButtons, Buttons, Win32Extra,
  Win32WSForms, Win32WSSpin, Spin, Win32WSMenus, Win32WSExtCtrls, WSExtCtrls,
  Dialogs, GraphUtil,
  gmap, gutil, TmSchema, InterfaceBase, uMetaDarkStyle;

type
  TWinControlDark = class(TWinControl);
  TCustomGroupBoxDark = class(TCustomGroupBox);

type

    { TWin32WSWinControlDark }

    TWin32WSWinControlDark = class(TWin32WSWinControl)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSScrollBarDark }

    TWin32WSScrollBarDark = class(TWin32WSScrollBar)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSCustomTreeViewDark }

    TWin32WSCustomTreeViewDark = class(TWin32WSCustomTreeView)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSCustomSplitterDark }

    TWin32WSCustomSplitterDark = class(TWin32WSCustomSplitter)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSStatusBarDark }

    TWin32WSStatusBarDark = class(TWin32WSStatusBar)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSCustomGroupBoxDark }

    TWin32WSCustomGroupBoxDark = class(TWin32WSCustomGroupBox)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSCustomRadioGroupDark }

    TWin32WSCustomRadioGroupDark = class(TWin32WSCustomGroupBoxDark)
    end;

    { TWin32WSCustomCheckGroupDark }

    TWin32WSCustomCheckGroupDark = class(TWin32WSCustomGroupBoxDark)
    end;

    { TWin32WSButtonDark }

    TWin32WSButtonDark = class(TWin32WSButton)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSBitBtnDark }

    TWin32WSBitBtnDark = class(TWin32WSBitBtn)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSCustomCheckBoxDark }

    TWin32WSCustomCheckBoxDark = class(TWin32WSCustomCheckBox)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSRadioButtonDark }

    TWin32WSRadioButtonDark = class(TWin32WSRadioButton)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSCustomPageDark }

    TWin32WSCustomPageDark = class(TWin32WSCustomPage)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSCustomTabControlDark }

    TWin32WSCustomTabControlDark = class(TWin32WSCustomTabControl)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
      class procedure ShowHide(const AWinControl: TWinControl); override;
    end;

    { TWin32WSCustomComboBoxDark }

    TWin32WSCustomComboBoxDark = class(TWin32WSCustomComboBox)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
    end;

    { TWin32WSCustomEditDark }

    TWin32WSCustomEditDark = class(TWin32WSCustomEdit)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class function GetDefaultColor(const AControl: TControl;
            const ADefaultColorType: TDefaultColorType): TColor; override;
    end;

    { TWin32WSCustomMemoDark }

    TWin32WSCustomMemoDark = class(TWin32WSCustomMemo)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSCustomListBoxDark }

    TWin32WSCustomListBoxDark = class(TWin32WSCustomListBox)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSCustomListViewDark }

    TWin32WSCustomListViewDark = class(TWin32WSCustomListView)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSScrollBoxDark }

    TWin32WSScrollBoxDark = class(TWin32WSScrollBox)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSCustomFormDark }

    TWin32WSCustomFormDark = class(TWin32WSCustomForm)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
    end;

    { TWin32WSTrackBarDark }

    TWin32WSTrackBarDark = class(TWin32WSTrackBar)
    published
      class function CreateHandle(const AWinControl: TWinControl;
            const AParams: TCreateParams): HWND; override;
      class procedure DefaultWndHandler(const AWinControl: TWinControl;
         var AMessage); override;
    end;

    { TWin32WSPopupMenuDark }

    TWin32WSPopupMenuDark = class(TWin32WSPopupMenu)
    published
      class procedure Popup(const APopupMenu: TPopupMenu; const X, Y: integer); override;
    end;

const
  ID_SUB_SCROLLBOX   = 1;
  ID_SUB_LISTBOX     = 2;
  ID_SUB_COMBOBOX    = 3;
  ID_SUB_STATUSBAR   = 4;
  ID_SUB_TRACKBAR    = 5;
  ID_SUB_LISTVIEW    = 6;
  ID_SUB_SCROLLBAR   = 7;
  DARK_BUTTON_OLD_PROC_PROP = 'LazDarkButtonOldProc';
  DARK_BUTTON_HOT_PROP = 'LazDarkButtonHot';
  DARK_BUTTON_BST_HOT = $0200;
  DARK_CHECKRADIO_OLD_PROC_PROP = 'LazDarkCheckRadioOldProc';
  DARK_CHECKRADIO_CALLING_OLD_PROC_PROP = 'LazDarkCheckRadioCallingOldProc';
  DARK_GROUPBOX_OLD_PROC_PROP = 'LazDarkGroupBoxOldProc';
  DARK_GROUPBOX_SYNC_CHILDREN_MSG = WM_APP + 138;

const
  themelib = 'uxtheme.dll';

const
  VSCLASS_DARK_EDIT      = 'DarkMode_CFD::Edit';
  VSCLASS_DARK_TAB1      = 'BrowserTab::Tab';
  VSCLASS_DARK_TAB2      = 'DarkMode_DarkTheme::Tab';
  VSCLASS_DARK_BUTTON    = 'DarkMode_Explorer::Button';
  VSCLASS_DARK_COMBOBOX  = 'DarkMode_CFD::Combobox';
  VSCLASS_DARK_SCROLLBAR = 'DarkMode_Explorer::ScrollBar';
  VSCLASS_DARK_HEADER    = 'Header';
  VSCLASS_PROGRESS_INDER = 'Indeterminate::Progress';

const
  MDL_MENU_SUBMENU     = #$EE#$A5#$B0; // $E970

  MDL_RADIO_FILLED     = #$EE#$A8#$BB; // $EA3B
  MDL_RADIO_CHECKED    = #$EE#$A4#$95; // $E915
  MDL_RADIO_OUTLINE    = #$EE#$A8#$BA; // $EA3A

  MDL_CHECKBOX_FILLED  = #$EE#$9C#$BB; // $E73B
  MDL_CHECKBOX_CHECKED = #$EE#$9C#$BE; // $E73E
  MDL_CHECKBOX_GRAYED  = #$EE#$9C#$BC; // $E73C
  MDL_CHECKBOX_OUTLINE = #$EE#$9C#$B9; // $E739

  MDL_SCROLLBOX_BTNLEFT  = #$EE#$B7#$99; // $E00E
  MDL_SCROLLBOX_BTNRIGHT = #$EE#$B7#$9A; // $E00F
  MDL_SCROLLBOX_BTNUP    = #$EE#$B7#$9B; // $E010
  MDL_SCROLLBOX_BTNDOWN  = #$EE#$B7#$9C; // $E011

  MDL_COMBOBOX_BTNDOWN  = #$EE#$A5#$B2; // $E972

type
  TThemeClassMap = specialize TMap<HTHEME, LPCWSTR, specialize TLess<HTHEME>>;
  TThemeWindowMap = specialize TMap<HTHEME, HWND, specialize TLess<HTHEME>>;

var
  ThemeClass: TThemeClassMap = nil;
  ThemeWindow: TThemeWindowMap = nil;
  Win32Theme: TWin32ThemeServices;
  OldUpDownWndProc: Windows.WNDPROC;
  CustomFormWndProc: Windows.WNDPROC;
  SysColor: TSysColors;
  SysColorBrush: array[0..COLOR_ENDCOLORS] of HBRUSH;
  DrawControl: TDrawControl;
  DefSubclassProc: function(hWnd: HWND; uMsg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
  SetWindowSubclass: function(hWnd: HWND; pfnSubclass: SUBCLASSPROC; uIdSubclass: UINT_PTR; dwRefData: DWORD_PTR): BOOL; stdcall;
  VSCLASS_DARK_TAB:PWideChar;

var
  TrampolineOpenThemeData: function(hwnd: HWND; pszClassList: LPCWSTR): HTHEME; stdcall =  nil;
  TrampolineOpenNCThemeData: function(hwnd: HWND; pszClassList: LPCWSTR): HTHEME; stdcall =  nil;
  TrampolineDrawThemeText: function(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; pszText: LPCWSTR; iCharCount: Integer;
                                    dwTextFlags, dwTextFlags2: DWORD; const pRect: TRect): HRESULT; stdcall = nil;
  TrampolineDrawThemeBackground: function(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect; pClipRect: Pointer): HRESULT; stdcall =  nil;

function DarkCheckRadioWndProc(Window: HWND; Msg: UInt;
  WParam: Windows.WParam; LParam: Windows.LParam): LResult; stdcall; forward;
procedure InstallDarkCheckRadioWndProc(Window: HWND); forward;
procedure InvalidateDarkChildPlacement(Window: HWND; ARedrawNow: Boolean); forward;
function GetSysColorBrushDark(nIndex: longint): HBRUSH; stdcall; forward;

procedure EnableDarkStyle(Window: HWND);
begin
  AllowDarkModeForWindow(Window, True);
  SetWindowTheme(Window, 'DarkMode_Explorer', nil);
  SendMessageW(Window, WM_THEMECHANGED, 0, 0);
end;

procedure PrepareDarkGroupedChildSizing(const AWinControl: TWinControl);
var
  I, ItemMinHeight: Integer;
  ChildWinControl: TWinControl;
begin
  if (AWinControl = nil) or
     (csDesigning in AWinControl.ComponentState) or
     not ((AWinControl is TCustomRadioGroup) or
          (AWinControl is TCustomCheckGroup)) then
    Exit;

  // Keep native checkbox/radio metrics stable at runtime. The default
  // shrink mode can leave only the final row compressed after group layout.
  AWinControl.ChildSizing.ShrinkVertical := crsAnchorAligning;
  ItemMinHeight := Max(23, Abs(AWinControl.Font.Height) + 8);
  for I := 0 to AWinControl.ControlCount - 1 do
    if AWinControl.Controls[I] is TWinControl then
    begin
      ChildWinControl := TWinControl(AWinControl.Controls[I]);
      ChildWinControl.Constraints.MinHeight :=
        Max(ChildWinControl.Constraints.MinHeight, ItemMinHeight);
    end;
end;

procedure SyncDarkGroupChildren(const AWinControl: TWinControl);
var
  I, ChildTop, MinChildTop, VisibleChildIndex, ItemCount, Columns, Rows,
    Row, Col, CellWidth, CellHeight, ItemHeight, Margin, BottomMargin: Integer;
  Child: TControl;
  ChildR, WorkR, TargetR: TRect;
  ChildWinControl: TWinControl;
  DC: HDC;
  TM: Windows.TextMetric;
  OldFont: HGDIOBJ;
  ColumnLayout: TColumnLayout;
  IsRadio: Boolean;
begin
  if not ((AWinControl is TCustomRadioGroup) or
          (AWinControl is TCustomCheckGroup)) then
    Exit;
  if csDesigning in AWinControl.ComponentState then
    Exit;

  PrepareDarkGroupedChildSizing(AWinControl);
  IsRadio := AWinControl is TCustomRadioGroup;
  if IsRadio then
  begin
    ItemCount := TCustomRadioGroup(AWinControl).Items.Count;
    Columns := Max(1, Min(TCustomRadioGroup(AWinControl).Columns,
      Max(1, ItemCount)));
    Rows := Max(1, TCustomRadioGroup(AWinControl).Rows);
    ColumnLayout := TCustomRadioGroup(AWinControl).ColumnLayout;
  end
  else
  begin
    ItemCount := TCustomCheckGroup(AWinControl).Items.Count;
    Columns := Max(1, Min(TCustomCheckGroup(AWinControl).Columns,
      Max(1, ItemCount)));
    Rows := Max(1, TCustomCheckGroup(AWinControl).Rows);
    ColumnLayout := TCustomCheckGroup(AWinControl).ColumnLayout;
  end;
  if ItemCount = 0 then
    Exit;

  if (AWinControl.Color = clDefault) or (AWinControl.Color = clWindow) or
     (AWinControl.Color = clBtnFace) then
  begin
    AWinControl.Color := SysColor[COLOR_BTNFACE];
    AWinControl.Brush.Color := SysColor[COLOR_BTNFACE];
  end;
  if (AWinControl.Font.Color = clDefault) or
     (AWinControl.Font.Color = clBtnText) or
     (AWinControl.Font.Color = clWindowText) then
    AWinControl.Font.Color := SysColor[COLOR_BTNTEXT];

  MinChildTop := 18;
  ItemHeight := 24;
  if AWinControl.HandleAllocated then
  begin
    DC := Windows.GetDC(AWinControl.Handle);
    if DC <> 0 then
    try
      OldFont := SelectObject(DC, AWinControl.Font.Reference.Handle);
      try
        TM := Default(Windows.TextMetric);
        if Windows.GetTextMetrics(DC, TM) then
        begin
          MinChildTop := Max(MinChildTop, TM.tmHeight + 4);
          ItemHeight := Max(20, TM.tmHeight + 8);
        end;
      finally
        if OldFont <> 0 then
          SelectObject(DC, OldFont);
      end;
    finally
      Windows.ReleaseDC(AWinControl.Handle, DC);
    end;
  end;

  Margin := Max(6, AWinControl.ChildSizing.LeftRightSpacing);
  BottomMargin := Max(6, AWinControl.ChildSizing.TopBottomSpacing);
  WorkR := AWinControl.ClientRect;
  Inc(WorkR.Left, Margin);
  Dec(WorkR.Right, Margin);
  WorkR.Top := MinChildTop;
  Dec(WorkR.Bottom, BottomMargin);

  if ColumnLayout = clHorizontalThenVertical then
    Rows := Max(1, ((ItemCount - 1) div Columns) + 1)
  else
    Columns := Max(1, ((ItemCount - 1) div Rows) + 1);

  CellWidth := Max(1, (WorkR.Right - WorkR.Left) div Columns);
  CellHeight := Max(ItemHeight, (WorkR.Bottom - WorkR.Top) div Rows);
  VisibleChildIndex := -1;
  for I := 0 to AWinControl.ControlCount - 1 do
  begin
    Child := AWinControl.Controls[I];
    if (Child is TWinControl) and Child.Visible then
    begin
      Inc(VisibleChildIndex);
      if VisibleChildIndex >= ItemCount then
        Continue;

      ChildWinControl := TWinControl(Child);
      ChildWinControl.BorderSpacing.CellAlignHorizontal := ccaFill;
      ChildWinControl.BorderSpacing.CellAlignVertical := ccaFill;
      if (ChildWinControl.Color = clDefault) or
         (ChildWinControl.Color = clWindow) or
         (ChildWinControl.Color = clBtnFace) then
      begin
        ChildWinControl.Color := SysColor[COLOR_BTNFACE];
        ChildWinControl.Brush.Color := SysColor[COLOR_BTNFACE];
      end;
      if (ChildWinControl.Font.Color = clDefault) or
         (ChildWinControl.Font.Color = clBtnText) or
         (ChildWinControl.Font.Color = clWindowText) then
        ChildWinControl.Font.Color := SysColor[COLOR_BTNTEXT];
      if ChildWinControl.HandleAllocated then
      begin
        EnableDarkStyle(ChildWinControl.Handle);
        InstallDarkCheckRadioWndProc(ChildWinControl.Handle);
        if ColumnLayout = clHorizontalThenVertical then
        begin
          Row := VisibleChildIndex div Columns;
          Col := VisibleChildIndex mod Columns;
        end
        else
        begin
          Row := VisibleChildIndex mod Rows;
          Col := VisibleChildIndex div Rows;
        end;
        TargetR.Left := WorkR.Left + Col * CellWidth;
        TargetR.Top := WorkR.Top + Row * CellHeight;
        TargetR.Right := Min(WorkR.Right, TargetR.Left + CellWidth);
        TargetR.Bottom := TargetR.Top + CellHeight;
        ChildTop := Max(TargetR.Top, MinChildTop);
        if (ChildWinControl.Left <> TargetR.Left) or
           (ChildWinControl.Top <> ChildTop) or
           (ChildWinControl.Width <> TargetR.Right - TargetR.Left) or
           (ChildWinControl.Height <> TargetR.Bottom - ChildTop) then
          ChildWinControl.SetBounds(TargetR.Left, ChildTop,
            TargetR.Right - TargetR.Left, TargetR.Bottom - ChildTop);
        GetWindowRect(ChildWinControl.Handle, ChildR);
        MapWindowPoints(0, AWinControl.Handle, ChildR, 2);
        if (ChildR.Left <> TargetR.Left) or (ChildR.Top <> ChildTop) or
           (ChildR.Right <> TargetR.Right) or
           (ChildR.Bottom <> TargetR.Bottom) then
          SetWindowPos(ChildWinControl.Handle, 0, TargetR.Left, ChildTop,
            TargetR.Right - TargetR.Left, TargetR.Bottom - ChildTop,
            SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOCOPYBITS);
        if ChildWinControl.HandleAllocated then
        begin
          EnableDarkStyle(ChildWinControl.Handle);
          InstallDarkCheckRadioWndProc(ChildWinControl.Handle);
        end;
        InvalidateRect(ChildWinControl.Handle, nil, True);
        RedrawWindow(ChildWinControl.Handle, nil, 0,
          RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
      end;
    end;
  end;
end;

procedure HideDarkGroupedDesignChildren(const AWinControl: TWinControl);
var
  I: Integer;
  ChildWinControl: TWinControl;
begin
  if not ((AWinControl is TCustomRadioGroup) or
          (AWinControl is TCustomCheckGroup)) then
    Exit;
  if not (csDesigning in AWinControl.ComponentState) then
    Exit;

  for I := 0 to AWinControl.ControlCount - 1 do
    if AWinControl.Controls[I] is TWinControl then
    begin
      ChildWinControl := TWinControl(AWinControl.Controls[I]);
      if ChildWinControl.HandleAllocated then
        ShowWindow(ChildWinControl.Handle, SW_HIDE);
    end;
end;

procedure PostDarkGroupedParentSync(const AWinControl: TWinControl);
var
  ParentControl: TWinControl;
begin
  if (AWinControl = nil) or (AWinControl.Parent = nil) then
    Exit;
  ParentControl := AWinControl.Parent;
  if not ((ParentControl is TCustomRadioGroup) or
          (ParentControl is TCustomCheckGroup)) then
    Exit;
  if ParentControl.HandleAllocated then
    PostMessage(ParentControl.Handle, DARK_GROUPBOX_SYNC_CHILDREN_MSG, 0, 0);
end;

procedure TryEnforceDarkStyleForCtrl(AWinControl:TWinControl);
begin
  if (AWinControl <> nil) then begin
     if DrawControl.BorderStyleOverride then
       if (AWinControl Is TCustomMemo) then
          (AWinControl As TCustomMemo).BorderStyle := bsNone;
     AWinControl.Color := clWindow;
     AWinControl.Font.Color := clWindowText;
     EnableDarkStyle(AWinControl.Handle);
  end;
end;

function IsSystemTextColor(AColor: TColor): Boolean;
begin
  Result := (AColor = clDefault) or (AColor = clBtnText) or
    (AColor = clWindowText);
end;

function IsSystemWindowColor(AColor: TColor): Boolean;
begin
  Result := (AColor = clDefault) or (AColor = clWindow) or
    (AColor = clBtnFace);
end;

function ResolveDarkSystemColor(AColor: TColor; ADefaultColorIndex: Integer): TColor;
begin
  case AColor of
    clBtnFace:
      Result := SysColor[COLOR_BTNFACE];
    clBtnText:
      Result := SysColor[COLOR_BTNTEXT];
    clWindow:
      Result := SysColor[COLOR_WINDOW];
    clWindowText:
      Result := SysColor[COLOR_WINDOWTEXT];
    clDefault:
      Result := SysColor[ADefaultColorIndex];
  else
    Result := AColor;
  end;
end;

procedure SetDarkControlColors(AWinControl: TWinControl);

  function ShouldPreserveFontColor: Boolean;
  begin
    Result := (AWinControl is TCustomGroupBox) or
      (AWinControl is TCustomCheckBox) or
      (AWinControl is TCustomEdit);
  end;

begin
  if (AWinControl <> nil) and not (csDesigning in AWinControl.ComponentState) then
  begin
    AWinControl.Color := SysColor[COLOR_BTNFACE];
    AWinControl.Brush.Color := SysColor[COLOR_BTNFACE];
    if IsSystemTextColor(AWinControl.Font.Color) or not ShouldPreserveFontColor then
      AWinControl.Font.Color := SysColor[COLOR_BTNTEXT];
  end;
end;

function DarkControlDefaultColor(const ADefaultColorType: TDefaultColorType): TColor;
begin
  case ADefaultColorType of
    dctBrush: Result := SysColor[COLOR_BTNFACE];
    dctFont: Result := SysColor[COLOR_BTNTEXT];
  else
    Result := clDefault;
  end;
end;

function DarkWindowDefaultColor(const ADefaultColorType: TDefaultColorType): TColor;
begin
  case ADefaultColorType of
    dctBrush: Result := SysColor[COLOR_WINDOW];
    dctFont: Result := SysColor[COLOR_WINDOWTEXT];
  else
    Result := clDefault;
  end;
end;

procedure DarkWin32ShowHide(AWinControl: TWinControl);
begin
  TWin32WSWinControl.ShowHide(AWinControl);
end;

procedure AllowDarkStyle(var Window: HWND);
begin
  if (Window <> 0) then
  begin
    AllowDarkModeForWindow(Window, True);
    Window:= 0;
  end;
end;

function ShouldForceDarkThemeClass(pszClassList: LPCWSTR): Boolean;
begin
  Result := (lstrcmpiW(pszClassList, VSCLASS_COMBOBOX) = 0) or
    (lstrcmpiW(pszClassList, VSCLASS_EDIT) = 0) or
    (lstrcmpiW(pszClassList, 'ListView') = 0) or
    (lstrcmpiW(pszClassList, VSCLASS_SCROLLBAR) = 0);
end;

function HSVToColor(H, S, V: Double): TColor;
var
  R, G, B: Integer;
begin
  HSVtoRGB(H, S, V, R, G, B);
  R := Min(MAXBYTE, R);
  G := Min(MAXBYTE, G);
  B := Min(MAXBYTE, B);
  Result:= RGBToColor(R, G, B);
end;

function Darker(Color: TColor; Factor: Integer): TColor; forward;

function Lighter(Color: TColor; Factor: Integer): TColor;
var
  H, S, V: Double;
begin
  // Invalid factor
  if (Factor <= 0) then
    Exit(Color);
  // Makes color darker
  if (Factor < 100) then begin
    Exit(darker(Color, 10000 div Factor));
  end;

  ColorToHSV(Color, H, S, V);

  V:= (Factor * V) / 100;
  if (V > High(Word)) then
  begin
    // Overflow, adjust saturation
    S -= V - High(Word);
    if (S < 0) then
      S := 0;
    V:= High(Word);
  end;

  Result:= HSVToColor(H, S, V);
end;

function Darker(Color: TColor; Factor: Integer): TColor;
var
  H, S, V: Double;
begin
  // Invalid factor
  if (Factor <= 0) then
    Exit(Color);
  // Makes color lighter
  if (Factor < 100) then
    Exit(lighter(Color, 10000 div Factor));

  ColorToHSV(Color, H, S, V);
  V := (V * 100) / Factor;

  Result:= HSVToColor(H, S, V);
end;

procedure DrawDarkPushButtonWindow(Window: HWND; DC: HDC);
var
  Info: PWin32WindowInfo;
  Control: TWinControl;
  R, CalcR, DrawR: TRect;
  Text: UnicodeString;
  State: LRESULT;
  FillColor, BorderColor, TextColor: TColor;
  Hot: Boolean;
  OldBkMode, YOff: Integer;
  OldTextColor: COLORREF;
  OldPenColor, OldBrushColor: COLORREF;
  OldPen, OldBrush, OldFont: HGDIOBJ;
  FontHandle: HFONT;
begin
  Info := GetWin32WindowInfo(Window);
  Control := nil;
  if Assigned(Info) then
    Control := Info^.WinControl;

  GetClientRect(Window, R);
  State := SendMessage(Window, BM_GETSTATE, 0, 0);
  Hot := IsWindowEnabled(Window) and (GetProp(Window, PChar(DARK_BUTTON_HOT_PROP)) <> 0);

  FillColor := SysColor[COLOR_BTNFACE];
  BorderColor := SysColor[COLOR_BTNHIGHLIGHT];
  if not IsWindowEnabled(Window) then
  begin
    FillColor := SysColor[COLOR_3DDKSHADOW];
    TextColor := SysColor[COLOR_GRAYTEXT];
  end
  else
  begin
    TextColor := SysColor[COLOR_BTNTEXT];
    // Honor an explicitly-chosen button font color (e.g. a red "Stop" caption).
    // A non-system Font.Color means the app deliberately set it; without this
    // the dark scheme always overrode it to COLOR_BTNTEXT. Uses the same
    // IsSystemTextColor idiom this unit applies elsewhere for dark text colors.
    if Assigned(Control) and (not IsSystemTextColor(Control.Font.Color)) then
      TextColor := Control.Font.Color;
    if (State and BST_PUSHED) <> 0 then
      FillColor := Darker(FillColor, 120);
    if Hot and ((State and BST_PUSHED) = 0) then
    begin
      FillColor := Lighter(FillColor, 125);
      BorderColor := Lighter(BorderColor, 135);
    end;
  end;

  OldPen := SelectObject(DC, GetStockObject(DC_PEN));
  OldBrush := SelectObject(DC, GetStockObject(DC_BRUSH));
  OldPenColor := SetDCPenColor(DC, ColorToRGB(BorderColor));
  OldBrushColor := SetDCBrushColor(DC, ColorToRGB(FillColor));
  Windows.RoundRect(DC, R.Left, R.Top, R.Right, R.Bottom, 8, 8);
  SetDCPenColor(DC, OldPenColor);
  SetDCBrushColor(DC, OldBrushColor);
  SelectObject(DC, OldBrush);
  SelectObject(DC, OldPen);

  InflateRect(R, -6, -2);
  if (State and BST_PUSHED) <> 0 then
    OffsetRect(R, 1, 1);

  if Assigned(Control) then
  begin
    Text := UTF8ToUTF16(Control.Caption);
    FontHandle := Control.Font.Reference.Handle;
  end
  else
  begin
    SetLength(Text, GetWindowTextLengthW(Window));
    if Length(Text) > 0 then
      SetLength(Text, GetWindowTextW(Window, PWideChar(Text), Length(Text) + 1));
    FontHandle := HFONT(SendMessage(Window, WM_GETFONT, 0, 0));
  end;

  OldFont := 0;
  if FontHandle <> 0 then
    OldFont := SelectObject(DC, FontHandle);
  OldBkMode := SetBkMode(DC, TRANSPARENT);
  OldTextColor := SetTextColor(DC, ColorToRGB(TextColor));
  // Word-wrap long captions: measure the caption single-line; if it is wider
  // than the available client rect, draw it multi-line, vertically centered via
  // a DT_CALCRECT height offset (DT_VCENTER is invalid with DT_WORDBREAK).
  // Captions that fit keep the existing single-line centered draw.
  CalcR := R;
  DrawTextW(DC, PWideChar(Text), Length(Text), CalcR,
    DT_CENTER or DT_SINGLELINE or DT_CALCRECT);
  if (Length(Text) > 0) and ((CalcR.Right - CalcR.Left) > (R.Right - R.Left)) then
  begin
    CalcR := R;
    DrawTextW(DC, PWideChar(Text), Length(Text), CalcR,
      DT_CENTER or DT_WORDBREAK or DT_CALCRECT);
    YOff := ((R.Bottom - R.Top) - (CalcR.Bottom - CalcR.Top)) div 2;
    if YOff < 0 then YOff := 0;
    DrawR := R;
    DrawR.Top := R.Top + YOff;
    DrawTextW(DC, PWideChar(Text), Length(Text), DrawR,
      DT_CENTER or DT_WORDBREAK);
  end
  else
    DrawTextW(DC, PWideChar(Text), Length(Text), R,
      DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS);
  SetTextColor(DC, OldTextColor);
  SetBkMode(DC, OldBkMode);
  if OldFont <> 0 then
    SelectObject(DC, OldFont);
end;

function CallDarkButtonOldProc(Window: HWND; Msg: UInt; WParam: Windows.WParam;
  LParam: Windows.LParam): LResult;
var
  OldProc: WNDPROC;
begin
  OldProc := WNDPROC(GetProp(Window, PChar(DARK_BUTTON_OLD_PROC_PROP)));
  if Assigned(OldProc) then
    Result := CallWindowProcW(OldProc, Window, Msg, WParam, LParam)
  else
    Result := WindowProc(Window, Msg, WParam, LParam);
end;

function DarkButtonWndProc(Window: HWND; Msg: UInt; WParam: Windows.WParam;
  LParam: Windows.LParam): LResult; stdcall;
var
  PS: PAINTSTRUCT;
  DC: HDC;
  MouseEvent: TTRACKMOUSEEVENT;
begin
  case Msg of
    WM_WINDOWPOSCHANGING:
      begin
        InvalidateDarkChildPlacement(Window, False);
        Result := CallDarkButtonOldProc(Window, Msg, WParam, LParam);
        Exit;
      end;
    WM_WINDOWPOSCHANGED, WM_SIZE, WM_MOVE:
      begin
        Result := CallDarkButtonOldProc(Window, Msg, WParam, LParam);
        InvalidateDarkChildPlacement(Window, True);
        Exit;
      end;
    WM_MOUSEMOVE:
      begin
        if GetProp(Window, PChar(DARK_BUTTON_HOT_PROP)) = 0 then
        begin
          SetProp(Window, PChar(DARK_BUTTON_HOT_PROP), THandle(1));
          MouseEvent := Default(TTRACKMOUSEEVENT);
          MouseEvent.cbSize := SizeOf(TTRACKMOUSEEVENT);
          MouseEvent.dwFlags := TME_LEAVE;
          MouseEvent.hwndTrack := Window;
          MouseEvent.dwHoverTime := HOVER_DEFAULT;
          _TrackMouseEvent(@MouseEvent);
          InvalidateRect(Window, nil, False);
        end;
      end;
    WM_MOUSELEAVE:
      begin
        if GetProp(Window, PChar(DARK_BUTTON_HOT_PROP)) <> 0 then
        begin
          RemoveProp(Window, PChar(DARK_BUTTON_HOT_PROP));
          InvalidateRect(Window, nil, False);
        end;
      end;
    WM_PAINT:
      begin
        DC := BeginPaint(Window, @PS);
        try
          DrawDarkPushButtonWindow(Window, DC);
        finally
          EndPaint(Window, @PS);
        end;
        Exit(0);
      end;
    WM_PRINTCLIENT:
      begin
        DrawDarkPushButtonWindow(Window, HDC(WParam));
        Exit(0);
      end;
    WM_ERASEBKGND:
      Exit(1);
    BM_GETSTATE:
      begin
        Result := CallDarkButtonOldProc(Window, Msg, WParam, LParam);
        if IsWindowEnabled(Window) and
           (GetProp(Window, PChar(DARK_BUTTON_HOT_PROP)) <> 0) then
          Result := Result or DARK_BUTTON_BST_HOT;
        Exit;
      end;
    WM_NCDESTROY:
      begin
        Result := CallDarkButtonOldProc(Window, Msg, WParam, LParam);
        RemoveProp(Window, PChar(DARK_BUTTON_OLD_PROC_PROP));
        RemoveProp(Window, PChar(DARK_BUTTON_HOT_PROP));
        Exit;
      end;
  end;

  Result := CallDarkButtonOldProc(Window, Msg, WParam, LParam);
end;

procedure InstallDarkButtonWndProc(Window: HWND);
var
  OldProc: LONG_PTR;
begin
  if Window = 0 then
    Exit;
  if GetProp(Window, PChar(DARK_BUTTON_OLD_PROC_PROP)) <> 0 then
    Exit;
  OldProc := SetWindowLongPtrW(Window, GWL_WNDPROC, PtrInt(@DarkButtonWndProc));
  if OldProc <> 0 then
    SetProp(Window, PChar(DARK_BUTTON_OLD_PROC_PROP), THandle(OldProc));
end;

function DarkControlFromWindow(Window: HWND): TWinControl;
var
  Info: PWin32WindowInfo;

  function IsLiveWindowControl(AControl: TWinControl): Boolean;
  begin
    Result := False;
    try
      if (AControl = nil) or (PPointer(AControl)^ = nil) then
        Exit;
      if (AControl.WidgetSetClass = nil) or
         (csDestroying in AControl.ComponentState) or
         (not AControl.HandleAllocated) or
         (HWND(AControl.Handle) <> Window) then
        Exit;
      Result := True;
    except
      Result := False;
    end;
  end;

begin
  Result := nil;
  if Window = 0 then
    Exit;

  Result := FindControl(Window);
  if IsLiveWindowControl(Result) then
    Exit;
  Result := nil;

  Info := GetWin32WindowInfo(Window);
  if Assigned(Info) and IsLiveWindowControl(Info^.WinControl) then
    Result := Info^.WinControl;

  if (Result = nil) and
     IsLiveWindowControl(TWinControl(GetProp(Window, PChar('WinControl')))) then
    Result := TWinControl(GetProp(Window, PChar('WinControl')));
end;

function DarkWindowHasLiveVisibleControl(Window: HWND): Boolean;
var
  Control: TWinControl;
begin
  Control := DarkControlFromWindow(Window);
  Result := (Control <> nil) and Control.Visible and IsWindowVisible(Window);
end;

function IsDarkGroupedDesignItem(const AWinControl: TWinControl): Boolean;
begin
  Result := False;
  try
    if (AWinControl = nil) or not (csDesigning in AWinControl.ComponentState) then
      Exit;
    Result := (AWinControl.Parent is TCustomRadioGroup) or
      (AWinControl.Parent is TCustomCheckGroup);
  except
    Result := True;
  end;
end;

function DarkControlTextColor(Window: HWND; ADefaultColor: TColor): TColor;
var
  Control: TWinControl;
begin
  Result := ADefaultColor;
  Control := DarkControlFromWindow(Window);
  if Control <> nil then
  begin
    Result := Control.Font.Color;
    if IsSystemTextColor(Result) then
      Result := Control.GetDefaultColor(dctFont);
  end;
  if Result = clDefault then
    Result := ADefaultColor;
end;

function DarkGroupedItemTextColor(const AWinControl: TWinControl;
  const AEnabled: Boolean): TColor;
begin
  if not AEnabled then
    Exit(SysColor[COLOR_GRAYTEXT]);

  Result := AWinControl.Font.Color;
  if IsSystemTextColor(Result) then
    Result := AWinControl.GetDefaultColor(dctFont);
  if Result = clDefault then
    Result := SysColor[COLOR_BTNTEXT];
end;

procedure DrawDarkGroupedItem(DC: HDC; const AItemRect: TRect;
  const AText: UnicodeString; const AChecked, AEnabled, AIsRadio: Boolean;
  const ATextColor: TColor);
var
  GlyphR, DotR, TextR: TRect;
  GlyphSize, MidY: Integer;
  OldPen, OldBrush: HGDIOBJ;
  OldTextColor: COLORREF;
  OldBkMode: Integer;
  BorderColor: TColor;
begin
  if (AItemRect.Right <= AItemRect.Left) or (AItemRect.Bottom <= AItemRect.Top) then
    Exit;

  GlyphSize := Max(11, Min(16, AItemRect.Bottom - AItemRect.Top - 6));
  GlyphR.Left := AItemRect.Left + 2;
  GlyphR.Top := AItemRect.Top + Max(0, (AItemRect.Bottom - AItemRect.Top - GlyphSize) div 2);
  GlyphR.Right := GlyphR.Left + GlyphSize;
  GlyphR.Bottom := GlyphR.Top + GlyphSize;

  if AEnabled then
    BorderColor := SysColor[COLOR_BTNTEXT]
  else
    BorderColor := SysColor[COLOR_GRAYTEXT];

  OldPen := SelectObject(DC, GetStockObject(DC_PEN));
  OldBrush := SelectObject(DC, GetStockObject(DC_BRUSH));
  try
    SetDCPenColor(DC, ColorToRGB(BorderColor));
    SetDCBrushColor(DC, ColorToRGB(SysColor[COLOR_BTNFACE]));
    if AIsRadio then
    begin
      Ellipse(DC, GlyphR.Left, GlyphR.Top, GlyphR.Right, GlyphR.Bottom);
      if AChecked then
      begin
        DotR := GlyphR;
        InflateRect(DotR, -4, -4);
        SetDCBrushColor(DC, ColorToRGB(BorderColor));
        Ellipse(DC, DotR.Left, DotR.Top, DotR.Right, DotR.Bottom);
      end;
    end
    else
    begin
      Rectangle(DC, GlyphR.Left, GlyphR.Top, GlyphR.Right, GlyphR.Bottom);
      if AChecked then
      begin
        MidY := GlyphR.Top + (GlyphR.Bottom - GlyphR.Top) div 2;
        MoveToEx(DC, GlyphR.Left + 3, MidY, nil);
        LineTo(DC, GlyphR.Left + 6, GlyphR.Bottom - 4);
        LineTo(DC, GlyphR.Right - 3, GlyphR.Top + 3);
      end;
    end;
  finally
    SelectObject(DC, OldBrush);
    SelectObject(DC, OldPen);
  end;

  TextR := AItemRect;
  TextR.Left := GlyphR.Right + 6;
  OldBkMode := SetBkMode(DC, TRANSPARENT);
  OldTextColor := SetTextColor(DC, ColorToRGB(ATextColor));
  DrawTextW(DC, PWideChar(AText), Length(AText), TextR,
    DT_LEFT or DT_SINGLELINE or DT_VCENTER);
  SetTextColor(DC, OldTextColor);
  SetBkMode(DC, OldBkMode);
end;

function IsDarkCheckRadioWindow(Window: HWND; out AIsRadio: Boolean): Boolean;
const
  DarkBSTypeMask = $0000000F;
  DarkBSCheckBox = $00000002;
  DarkBSAutoCheckBox = $00000003;
  DarkBSRadioButton = $00000004;
  DarkBS3State = $00000005;
  DarkBSAuto3State = $00000006;
  DarkBSAutoRadioButton = $00000009;
var
  Style, ButtonStyle: PtrUInt;
begin
  AIsRadio := False;
  Style := PtrUInt(GetWindowLongPtrW(Window, GWL_STYLE));
  ButtonStyle := Style and DarkBSTypeMask;
  AIsRadio := ButtonStyle in [DarkBSRadioButton, DarkBSAutoRadioButton];
  Result := AIsRadio or (ButtonStyle in [DarkBSCheckBox, DarkBSAutoCheckBox,
    DarkBS3State, DarkBSAuto3State]);
  if Result and ((Style and BS_PUSHLIKE) <> 0) then
    Result := False;
end;

procedure DrawDarkCheckRadioWindow(Window: HWND; DC: HDC);
var
  R: TRect;
  Text: UnicodeString;
  Control: TWinControl;
  FontHandle, OldFont: HGDIOBJ;
  Brush: HBRUSH;
  CheckState: LRESULT;
  IsRadio, Checked, Enabled: Boolean;
  TextColor: TColor;
begin
  if not IsDarkCheckRadioWindow(Window, IsRadio) then
    Exit;

  GetClientRect(Window, R);
  Brush := CreateSolidBrush(ColorToRGB(SysColor[COLOR_BTNFACE]));
  try
    FillRect(DC, R, Brush);
  finally
    DeleteObject(Brush);
  end;

  Control := DarkControlFromWindow(Window);
  if Control <> nil then
  begin
    Text := UTF8ToUTF16(Control.Caption);
    FontHandle := Control.Font.Reference.Handle;
  end
  else
  begin
    SetLength(Text, GetWindowTextLengthW(Window));
    if Length(Text) > 0 then
      SetLength(Text, GetWindowTextW(Window, PWideChar(Text), Length(Text) + 1));
    FontHandle := HFONT(SendMessage(Window, WM_GETFONT, 0, 0));
  end;

  OldFont := 0;
  if FontHandle <> 0 then
    OldFont := SelectObject(DC, FontHandle);
  try
    CheckState := SendMessage(Window, BM_GETCHECK, 0, 0);
    Checked := CheckState = BST_CHECKED;
    Enabled := IsWindowEnabled(Window);
    if Enabled then
      TextColor := DarkControlTextColor(Window, SysColor[COLOR_BTNTEXT])
    else
      TextColor := SysColor[COLOR_GRAYTEXT];
    DrawDarkGroupedItem(DC, R, Text, Checked, Enabled, IsRadio, TextColor);
  finally
    if OldFont <> 0 then
      SelectObject(DC, OldFont);
  end;
end;

procedure InvalidateDarkChildPlacement(Window: HWND; ARedrawNow: Boolean);
var
  Parent: HWND;
  R: TRect;
begin
  if Window = 0 then Exit;

  Parent := GetParent(Window);
  if (Parent <> 0) and GetWindowRect(Window, R) then
  begin
    MapWindowPoints(0, Parent, R, 2);
    InvalidateRect(Parent, @R, True);
    if ARedrawNow then
      RedrawWindow(Parent, nil, 0, RDW_UPDATENOW or RDW_ALLCHILDREN);
  end;

  InvalidateRect(Window, nil, True);
  if ARedrawNow then
    RedrawWindow(Window, nil, 0, RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
end;

function CallDarkCheckRadioOldProc(Window: HWND; Msg: UInt;
  WParam: Windows.WParam; LParam: Windows.LParam): LResult;
var
  OldProc: WNDPROC;
begin
  OldProc := WNDPROC(GetProp(Window, PChar(DARK_CHECKRADIO_OLD_PROC_PROP)));
  if not Assigned(OldProc) or
     (PtrInt(OldProc) = PtrInt(@DarkCheckRadioWndProc)) or
     (GetProp(Window, PChar(DARK_CHECKRADIO_CALLING_OLD_PROC_PROP)) <> 0) then
    Exit(WindowProc(Window, Msg, WParam, LParam));

  SetProp(Window, PChar(DARK_CHECKRADIO_CALLING_OLD_PROC_PROP), THandle(1));
  try
    Result := CallWindowProcW(OldProc, Window, Msg, WParam, LParam);
  finally
    RemoveProp(Window, PChar(DARK_CHECKRADIO_CALLING_OLD_PROC_PROP));
  end;
end;

function DarkCheckRadioWndProc(Window: HWND; Msg: UInt;
  WParam: Windows.WParam; LParam: Windows.LParam): LResult; stdcall;
var
  PS: PAINTSTRUCT;
  DC: HDC;
  Control: TWinControl;
begin
  case Msg of
    WM_WINDOWPOSCHANGING:
      begin
        InvalidateDarkChildPlacement(Window, False);
        Result := CallDarkCheckRadioOldProc(Window, Msg, WParam, LParam);
        Exit;
      end;
    WM_WINDOWPOSCHANGED, WM_SIZE, WM_MOVE:
      begin
        Result := CallDarkCheckRadioOldProc(Window, Msg, WParam, LParam);
        InvalidateDarkChildPlacement(Window, True);
        Exit;
      end;
  end;

  Control := DarkControlFromWindow(Window);
  if (Msg <> WM_NCDESTROY) and
     (((Control <> nil) and (not Control.Visible)) or
      (not IsWindowVisible(Window))) then
  begin
    case Msg of
      WM_PAINT, WM_PRINTCLIENT, WM_ERASEBKGND:
        Exit(CallDefaultWindowProc(Window, Msg, WParam, LParam));
    end;
    if Control <> nil then
      Exit(CallDarkCheckRadioOldProc(Window, Msg, WParam, LParam))
    else
      Exit(CallDefaultWindowProc(Window, Msg, WParam, LParam));
  end;

  if (Control <> nil) and IsDarkGroupedDesignItem(Control) then
  begin
    case Msg of
      WM_PAINT, WM_PRINTCLIENT, WM_ERASEBKGND:
        Exit(0);
      WM_SETTEXT, WM_SETFONT, WM_ENABLE, WM_SETFOCUS, WM_KILLFOCUS,
      WM_LBUTTONDOWN, WM_LBUTTONUP, WM_KEYDOWN, WM_KEYUP, WM_CHAR,
      WM_DEADCHAR, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_SYSCHAR,
      WM_SYSDEADCHAR, BM_SETCHECK, BM_SETSTATE:
        Exit(CallDefaultWindowProc(Window, Msg, WParam, LParam));
    end;
  end;

  case Msg of
    WM_PAINT:
      begin
        DC := BeginPaint(Window, @PS);
        try
          DrawDarkCheckRadioWindow(Window, DC);
        finally
          EndPaint(Window, @PS);
        end;
        Exit(0);
      end;
    WM_PRINTCLIENT:
      begin
        DrawDarkCheckRadioWindow(Window, HDC(WParam));
        Exit(0);
      end;
    WM_ERASEBKGND:
      Exit(1);
    WM_SETTEXT, WM_SETFONT, WM_ENABLE, WM_SETFOCUS, WM_KILLFOCUS,
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_KEYDOWN, WM_KEYUP, BM_SETCHECK,
    BM_SETSTATE:
      begin
        Result := CallDarkCheckRadioOldProc(Window, Msg, WParam, LParam);
        RedrawWindow(Window, nil, 0,
          RDW_INVALIDATE or RDW_ERASE or RDW_UPDATENOW);
        Exit;
      end;
    WM_NCDESTROY:
      begin
        Result := CallDarkCheckRadioOldProc(Window, Msg, WParam, LParam);
        RemoveProp(Window, PChar(DARK_CHECKRADIO_CALLING_OLD_PROC_PROP));
        RemoveProp(Window, PChar(DARK_CHECKRADIO_OLD_PROC_PROP));
        Exit;
      end;
  end;

  Result := CallDarkCheckRadioOldProc(Window, Msg, WParam, LParam);
end;

procedure InstallDarkCheckRadioWndProc(Window: HWND);
var
  CurrentProc, OldProc: LONG_PTR;
  IsRadio: Boolean;
begin
  if Window = 0 then
    Exit;
  if GetProp(Window, PChar(DARK_CHECKRADIO_OLD_PROC_PROP)) <> 0 then
    Exit;
  CurrentProc := GetWindowLongPtrW(Window, GWL_WNDPROC);
  if CurrentProc = PtrInt(@DarkCheckRadioWndProc) then
    Exit;
  if not IsDarkCheckRadioWindow(Window, IsRadio) then
    Exit;
  OldProc := SetWindowLongPtrW(Window, GWL_WNDPROC, PtrInt(@DarkCheckRadioWndProc));
  if OldProc <> 0 then
  begin
    if GetProp(Window, PChar(DARK_CHECKRADIO_OLD_PROC_PROP)) <> 0 then
      RemoveProp(Window, PChar(DARK_CHECKRADIO_OLD_PROC_PROP));
    SetProp(Window, PChar(DARK_CHECKRADIO_OLD_PROC_PROP), THandle(OldProc));
  end;
end;

procedure DrawDarkGroupedControlItems(DC: HDC; const AWinControl: TWinControl;
  const AClientRect, ACaptionRect: TRect);
var
  RadioGroup: TCustomRadioGroup;
  CheckGroup: TCustomCheckGroup;
  Button: TControl;
  Items: TStrings;
  ColumnLayout: TColumnLayout;
  I, ChildIndex, VisibleChildIndex, ItemCount, Columns, Rows, Row, Col,
    CellWidth, CellHeight, ItemHeight, ItemTop: Integer;
  ItemR, WorkR: TRect;
  IsRadio, Checked, Enabled: Boolean;
  Text: UnicodeString;
  TM: Windows.TextMetric;
begin
  if (AWinControl = nil) or not (csDesigning in AWinControl.ComponentState) then
    Exit;

  IsRadio := AWinControl is TCustomRadioGroup;
  if IsRadio then
  begin
    RadioGroup := TCustomRadioGroup(AWinControl);
    Items := RadioGroup.Items;
    ItemCount := Items.Count;
    Columns := Max(1, Min(RadioGroup.Columns, Max(1, ItemCount)));
    Rows := Max(1, RadioGroup.Rows);
    ColumnLayout := RadioGroup.ColumnLayout;
  end
  else if AWinControl is TCustomCheckGroup then
  begin
    CheckGroup := TCustomCheckGroup(AWinControl);
    Items := CheckGroup.Items;
    ItemCount := Items.Count;
    Columns := Max(1, Min(CheckGroup.Columns, Max(1, ItemCount)));
    Rows := Max(1, CheckGroup.Rows);
    ColumnLayout := CheckGroup.ColumnLayout;
  end
  else
    Exit;

  if ItemCount = 0 then
    Exit;

  FillChar(TM{%H-}, SizeOf(TM), 0);
  if Windows.GetTextMetrics(DC, TM) then
    ItemHeight := Max(20, TM.tmHeight + 8)
  else
    ItemHeight := 24;

  WorkR := AClientRect;
  Inc(WorkR.Left, 10);
  Dec(WorkR.Right, 8);
  ItemTop := Max(18, ACaptionRect.Bottom + 2);
  WorkR.Top := ItemTop;
  Dec(WorkR.Bottom, 6);

  if ColumnLayout = clHorizontalThenVertical then
    Rows := Max(1, ((ItemCount - 1) div Columns) + 1)
  else
    Columns := Max(1, ((ItemCount - 1) div Rows) + 1);

  CellWidth := Max(1, (WorkR.Right - WorkR.Left) div Columns);
  CellHeight := Max(ItemHeight, (WorkR.Bottom - WorkR.Top) div Rows);

  for I := 0 to ItemCount - 1 do
  begin
    Button := nil;
    VisibleChildIndex := -1;
    for ChildIndex := 0 to AWinControl.ControlCount - 1 do
    begin
      if not AWinControl.Controls[ChildIndex].Visible then
        Continue;
      Inc(VisibleChildIndex);
      if VisibleChildIndex = I then
      begin
        Button := AWinControl.Controls[ChildIndex];
        Break;
      end;
    end;

    if IsRadio then
    begin
      RadioGroup := TCustomRadioGroup(AWinControl);
      Checked := RadioGroup.ItemIndex = I;
    end
    else
      Checked := (Button is TCheckBox) and TCheckBox(Button).Checked;

    if ColumnLayout = clHorizontalThenVertical then
    begin
      Row := I div Columns;
      Col := I mod Columns;
    end
    else
    begin
      Row := I mod Rows;
      Col := I div Rows;
    end;

    ItemR.Left := WorkR.Left + Col * CellWidth;
    ItemR.Top := WorkR.Top + Row * CellHeight;
    ItemR.Right := Min(WorkR.Right, ItemR.Left + CellWidth);
    ItemR.Bottom := Min(WorkR.Bottom, ItemR.Top + CellHeight);
    Text := UTF8ToUTF16(Items[I]);
    Enabled := AWinControl.Enabled and ((Button = nil) or Button.Enabled);
    DrawDarkGroupedItem(DC, ItemR, Text, Checked, Enabled, IsRadio,
      DarkGroupedItemTextColor(AWinControl, Enabled));
  end;
end;

procedure DrawDarkGroupBoxWindow(Window: HWND; DC: HDC);
var
  R, BorderR, TextR: TRect;
  Text: UnicodeString;
  Control: TWinControl;
  FontHandle, OldFont, OldPen, OldBrush: HGDIOBJ;
  OldBkMode: Integer;
  OldTextColor: COLORREF;
  Brush: HBRUSH;
  TextColor: TColor;

  procedure ExcludeChildWindows;
  var
    Child: HWND;
    ChildR: TRect;
    I: Integer;
    ChildWinControl: TWinControl;
  begin
    Child := GetWindow(Window, GW_CHILD);
    while Child <> 0 do
    begin
      if IsWindowVisible(Child) and GetWindowRect(Child, ChildR) then
      begin
        MapWindowPoints(0, Window, ChildR, 2);
        ExcludeClipRect(DC, ChildR.Left, ChildR.Top, ChildR.Right, ChildR.Bottom);
      end;
      Child := GetWindow(Child, GW_HWNDNEXT);
    end;

    if Control = nil then
      Exit;
    for I := 0 to Control.ControlCount - 1 do
      if Control.Controls[I] is TWinControl then
      begin
        ChildWinControl := TWinControl(Control.Controls[I]);
        if ChildWinControl.HandleAllocated and ChildWinControl.Visible and
           IsWindowVisible(ChildWinControl.Handle) and
           GetWindowRect(ChildWinControl.Handle, ChildR) then
        begin
          MapWindowPoints(0, Window, ChildR, 2);
          ExcludeClipRect(DC, ChildR.Left, ChildR.Top, ChildR.Right, ChildR.Bottom);
        end;
      end;
  end;
begin
  Control := DarkControlFromWindow(Window);
  if Control <> nil then
    HideDarkGroupedDesignChildren(Control);

  GetClientRect(Window, R);
  ExcludeChildWindows;
  Brush := CreateSolidBrush(ColorToRGB(SysColor[COLOR_BTNFACE]));
  try
    FillRect(DC, R, Brush);
  finally
    DeleteObject(Brush);
  end;

  if Control <> nil then
  begin
    Text := UTF8ToUTF16(Control.Caption);
    FontHandle := Control.Font.Reference.Handle;
  end
  else
  begin
    SetLength(Text, GetWindowTextLengthW(Window));
    if Length(Text) > 0 then
      SetLength(Text, GetWindowTextW(Window, PWideChar(Text), Length(Text) + 1));
    FontHandle := HFONT(SendMessage(Window, WM_GETFONT, 0, 0));
  end;

  OldFont := 0;
  if FontHandle <> 0 then
    OldFont := SelectObject(DC, FontHandle);

  OldBkMode := SetBkMode(DC, TRANSPARENT);
  TextR := R;
  Inc(TextR.Left, 8);
  Dec(TextR.Right, 8);
  TextR.Bottom := TextR.Top;
  DrawTextW(DC, PWideChar(Text), Length(Text), TextR,
    DT_LEFT or DT_SINGLELINE or DT_CALCRECT);

  BorderR := R;
  Inc(BorderR.Top, Max(1, (TextR.Bottom - TextR.Top) div 2));
  Dec(BorderR.Right);
  Dec(BorderR.Bottom);

  OldPen := SelectObject(DC, GetStockObject(DC_PEN));
  OldBrush := SelectObject(DC, GetStockObject(HOLLOW_BRUSH));
  SetDCPenColor(DC, ColorToRGB(SysColor[COLOR_BTNHIGHLIGHT]));
  RoundRect(DC, BorderR.Left, BorderR.Top, BorderR.Right, BorderR.Bottom, 8, 8);
  SelectObject(DC, OldBrush);
  SelectObject(DC, OldPen);

  Brush := CreateSolidBrush(ColorToRGB(SysColor[COLOR_BTNFACE]));
  try
    FillRect(DC, TextR, Brush);
  finally
    DeleteObject(Brush);
  end;

  TextColor := DarkControlTextColor(Window, SysColor[COLOR_BTNTEXT]);
  OldTextColor := SetTextColor(DC, ColorToRGB(TextColor));
  DrawTextW(DC, PWideChar(Text), Length(Text), TextR,
    DT_LEFT or DT_SINGLELINE or DT_END_ELLIPSIS);
  SetTextColor(DC, OldTextColor);
  DrawDarkGroupedControlItems(DC, Control, R, TextR);
  SetBkMode(DC, OldBkMode);
  if OldFont <> 0 then
    SelectObject(DC, OldFont);
end;

function CallDarkGroupBoxOldProc(Window: HWND; Msg: UInt;
  WParam: Windows.WParam; LParam: Windows.LParam): LResult;
var
  OldProc: WNDPROC;
begin
  OldProc := WNDPROC(GetProp(Window, PChar(DARK_GROUPBOX_OLD_PROC_PROP)));
  if Assigned(OldProc) then
    Result := CallWindowProcW(OldProc, Window, Msg, WParam, LParam)
  else
    Result := WindowProc(Window, Msg, WParam, LParam);
end;

function DarkGroupBoxWndProc(Window: HWND; Msg: UInt;
  WParam: Windows.WParam; LParam: Windows.LParam): LResult; stdcall;
var
  PS: PAINTSTRUCT;
  DC: HDC;
  Control: TWinControl;
begin
  Control := DarkControlFromWindow(Window);
  if (Msg <> WM_NCDESTROY) and
     ((Control = nil) or (not Control.Visible) or
      (not IsWindowVisible(Window))) then
  begin
    case Msg of
      WM_PAINT, WM_PRINTCLIENT, WM_ERASEBKGND:
        Exit(CallDefaultWindowProc(Window, Msg, WParam, LParam));
    end;
    if Control <> nil then
      Exit(CallDarkGroupBoxOldProc(Window, Msg, WParam, LParam))
    else
      Exit(CallDefaultWindowProc(Window, Msg, WParam, LParam));
  end;

  case Msg of
    DARK_GROUPBOX_SYNC_CHILDREN_MSG:
      begin
        if Control <> nil then
        begin
          SyncDarkGroupChildren(Control);
          InvalidateRect(Window, nil, True);
        end;
        Exit(0);
      end;
    WM_CTLCOLORSTATIC, WM_CTLCOLORBTN:
      begin
        DC := HDC(WParam);
        SetBkColor(DC, ColorToRGB(SysColor[COLOR_BTNFACE]));
        SetTextColor(DC, ColorToRGB(SysColor[COLOR_BTNTEXT]));
        SetBkMode(DC, TRANSPARENT);
        Exit(LResult(GetSysColorBrushDark(COLOR_BTNFACE)));
      end;
    WM_SIZE, WM_WINDOWPOSCHANGED:
      begin
        Result := CallDarkGroupBoxOldProc(Window, Msg, WParam, LParam);
        Control := DarkControlFromWindow(Window);
        if (Control is TCustomRadioGroup) or (Control is TCustomCheckGroup) then
          PostMessage(Window, DARK_GROUPBOX_SYNC_CHILDREN_MSG, 0, 0);
        Exit;
      end;
    WM_PAINT:
      begin
        DC := BeginPaint(Window, @PS);
        try
          DrawDarkGroupBoxWindow(Window, DC);
        finally
          EndPaint(Window, @PS);
        end;
        Exit(0);
      end;
    WM_PRINTCLIENT:
      begin
        DrawDarkGroupBoxWindow(Window, HDC(WParam));
        Exit(0);
      end;
    WM_ERASEBKGND:
      Exit(1);
    WM_NCDESTROY:
      begin
        Result := CallDarkGroupBoxOldProc(Window, Msg, WParam, LParam);
        RemoveProp(Window, PChar(DARK_GROUPBOX_OLD_PROC_PROP));
        Exit;
      end;
  end;

  Result := CallDarkGroupBoxOldProc(Window, Msg, WParam, LParam);
end;

procedure InstallDarkGroupBoxWndProc(Window: HWND);
var
  CurrentProc, OldProc: LONG_PTR;
begin
  if Window = 0 then
    Exit;
  CurrentProc := GetWindowLongPtrW(Window, GWL_WNDPROC);
  if CurrentProc = PtrInt(@DarkGroupBoxWndProc) then
    Exit;
  OldProc := SetWindowLongPtrW(Window, GWL_WNDPROC, PtrInt(@DarkGroupBoxWndProc));
  if OldProc <> 0 then
  begin
    if GetProp(Window, PChar(DARK_GROUPBOX_OLD_PROC_PROP)) <> 0 then
      RemoveProp(Window, PChar(DARK_GROUPBOX_OLD_PROC_PROP));
    SetProp(Window, PChar(DARK_GROUPBOX_OLD_PROC_PROP), THandle(OldProc));
  end;
end;

{
  Fill rectangle gradient
}
function FillGradient(hDC: HDC; Start, Finish: TColor; ARect: TRect; dwMode: ULONG): Boolean;
var
  cc: TFPColor;
  gRect: GRADIENT_RECT;
  vert: array[0..1] of TRIVERTEX;
begin
  cc:= TColorToFPColor(Start);

  vert[0].x      := ARect.Left;
  vert[0].y      := ARect.Top;
  vert[0].Red    := cc.red;
  vert[0].Green  := cc.green;
  vert[0].Blue   := cc.blue;
  vert[0].Alpha  := cc.alpha;

  cc:= TColorToFPColor(ColorToRGB(Finish));

  vert[1].x      := ARect.Right;
  vert[1].y      := ARect.Bottom;
  vert[1].Red    := cc.red;
  vert[1].Green  := cc.green;
  vert[1].Blue   := cc.blue;
  vert[1].Alpha  := cc.alpha;

  gRect.UpperLeft  := 0;
  gRect.LowerRight := 1;
  Result:= JwaWinGDI.GradientFill(hDC, vert, 2, @gRect, 1, dwMode);
end;

function GetNonClientMenuBorderRect(Window: HWND): TRect;
var
  R, W: TRect;
begin
  GetClientRect(Window, @R);
  // Map to screen coordinate space
  MapWindowPoints(Window, 0, @R, 2);
  GetWindowRect(Window, @W);
  OffsetRect(R, -W.Left, -W.Top);
  Result:= Classes.Rect(R.Left, R.Top - 1, R.Right, R.Top);
end;

{
  Set menu background color
}
procedure SetMenuBackground(Menu: HMENU);
var
  MenuInfo: TMenuInfo;
begin
  MenuInfo:= Default(TMenuInfo);
  MenuInfo.cbSize:= SizeOf(MenuInfo);
  MenuInfo.fMask:= MIM_BACKGROUND or MIM_APPLYTOSUBMENUS;
  MenuInfo.hbrBack:= CreateSolidBrush(SysColor[COLOR_MENU]{RGBToColor(45, 45, 45)});
  SetMenuInfo(Menu, @MenuInfo);
end;

{
  Set control colors
}
procedure SetControlColors(Control: TControl; Canvas: HDC);
var
  Color: TColor;
begin
  // Set background color
  Color:= Control.Color;
  if IsSystemWindowColor(Color) then
  begin
    Color:= Control.GetDefaultColor(dctBrush);
  end;
  Color := ResolveDarkSystemColor(Color, COLOR_BTNFACE);
  SetBkColor(Canvas, ColorToRGB(Color));

  // Set text color
  Color:= Control.Font.Color;
  if IsSystemTextColor(Color) then
  begin
    Color:= Control.GetDefaultColor(dctFont);
  end;
  Color := ResolveDarkSystemColor(Color, COLOR_BTNTEXT);
  SetTextColor(Canvas, ColorToRGB(Color));
end;

function GetControlColorBrush(Control: TWinControl): HBRUSH;
var
  Color: TColor;
begin
  Color := Control.Color;
  if IsSystemWindowColor(Color) then
  begin
    Color := Control.GetDefaultColor(dctBrush);
    if Color = clWindow then
      Result := GetSysColorBrushDark(COLOR_WINDOW)
    else
      Result := GetSysColorBrushDark(COLOR_BTNFACE)
  end
  else
    Result := Control.Brush.Reference.Handle;
end;

{ TWin32WSUpDownControlDark }

procedure DrawUpDownArrow(Window: HWND; Canvas: TCanvas; ARect: TRect; AType: TUDAlignButton);
var
  j: integer;
  ax, ay, ah, aw: integer;

  procedure Calculate(var a, b: Integer);
  var
    tmp: Double;
  begin
    tmp:= Double(a + 1) / 2;
    if (tmp > b) then
    begin
      a:= 2 * b - 1;
      b:= (a + 1) div 2;
    end
    else begin
      b:= Round(tmp);
      a:= 2 * b - 1;
    end;
    b:= Max(b, 3);
    a:= Max(a, 5);
  end;

begin
  aw:= ARect.Width div 2;
  ah:= ARect.Height div 2;

  if IsWindowEnabled(Window) then
    Canvas.Pen.Color:= clBtnText
  else begin
    Canvas.Pen.Color:= clGrayText;
  end;
  if (AType in [udLeft, udRight]) then
    Calculate(ah, aw)
  else begin
    Calculate(aw, ah);
  end;
  ax:= ARect.Left + (ARect.Width - aw) div 2;
  ay:= ARect.Top + (ARect.Height - ah) div 2;

  case AType of
    udLeft:
      begin
        for j:= 0 to ah div 2 do
        begin
          Canvas.MoveTo(ax + aw - j - 2, ay + j);
          Canvas.LineTo(ax + aw - j - 2, ay + ah - j - 1);
        end;
      end;
    udRight:
      begin
        for j:= 0 to ah div 2 do
        begin
          Canvas.MoveTo(ax + j, ay + j);
          Canvas.LineTo(ax + j, ay + ah - j - 1);
        end;
      end;
    udTop:
      begin
        for j:= 0 to aw div 2 do
        begin
          Canvas.MoveTo(ax + j, ay + ah - j - 1);
          Canvas.LineTo(ax + aw - j, ay + ah - j - 1);
        end;
      end;
    udBottom:
    begin
      for j:= 0 to aw div 2 do
      begin
        Canvas.MoveTo(ax + j, ay + j);
        Canvas.LineTo(ax + aw - j, ay + j);
      end;
    end;
  end;
end;

function UpDownWndProc(Window: HWND; Msg: UINT; wParam: Windows.WPARAM; lParam: Windows.LPARAM): LRESULT; stdcall;
var
  DC: HDC;
  L, R: TRect;
  rcDst: TRect;
  ARect: TRect;
  PS: PAINTSTRUCT;
  LCanvas : TCanvas;
  LButton, RButton: TUDAlignButton;
begin
  case Msg of
    WM_PAINT:
    begin
      DC := BeginPaint(Window, @ps);
      LCanvas := TCanvas.Create;
      try
        LCanvas.Handle:= DC;

        GetClientRect(Window, @ARect);

        LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
        LCanvas.FillRect(ps.rcPaint);

        L:= ARect;
        R:= ARect;

        if (GetWindowLongPtr(Window, GWL_STYLE) and UDS_HORZ <> 0) then
        begin
          LButton:= udLeft;
          RButton:= udRight;
          R.Left:= R.Width div 2;
          L.Right:= L.Right - L.Width div 2;
        end
        else begin
          LButton:= udTop;
          RButton:= udBottom;
          R.Top:= R.Height div 2;
          L.Bottom:= L.Bottom - L.Height div 2;
        end;

        if (IntersectRect(rcDst, L, PS.rcPaint)) then
        begin
          LCanvas.Pen.Color:= SysColor[COLOR_BTNSHADOW];//RGBToColor(38, 38, 38);
          LCanvas.RoundRect(L, 4, 4);
          InflateRect(L, -1, -1);
          LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];//RGBToColor(92, 92, 92);
          LCanvas.RoundRect(L, 4, 4);
          DrawUpDownArrow(Window, LCanvas, L, LButton);
        end;

        if (IntersectRect(rcDst, R, PS.rcPaint)) then
        begin
          LCanvas.Pen.Color:= SysColor[COLOR_BTNSHADOW];//RGBToColor(38, 38, 38);
          LCanvas.RoundRect(R, 4, 4);
          InflateRect(R, -1, -1);
          LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];//RGBToColor(92, 92, 92);
          LCanvas.RoundRect(R, 4, 4);
          DrawUpDownArrow(Window, LCanvas, R, RButton);
        end;
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
      EndPaint(Window, @ps);
      Result:= 0;
    end;
  WM_ERASEBKGND:
    begin
      Exit(1);
    end;
    else begin
      if Assigned(OldUpDownWndProc) and (Pointer(OldUpDownWndProc) <> Pointer(@UpDownWndProc)) then
        Result:= CallWindowProc(OldUpDownWndProc, Window, Msg, WParam, LParam)
      else
        Result:= DefWindowProcW(Window, Msg, WParam, LParam);
    end;
  end;
end;

{ TWin32WSTrackBarDark }

function TrackBarWindowProc(Window: HWND; Msg: UINT; wParam: Windows.WPARAM; lParam: Windows.LPARAM; uISubClass: UINT_PTR; dwRefData: DWORD_PTR): LRESULT; stdcall;
begin
  if Msg = WM_ERASEBKGND then
    Result := 1
  else
    Result := DefSubclassProc(Window, Msg, WParam, LParam);
end;

class function TWin32WSTrackBarDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  AWinControl.Color:= SysColor[COLOR_BTNFACE];
  Result:= inherited CreateHandle(AWinControl, AParams);
  SetWindowSubclass(Result, @TrackBarWindowProc, ID_SUB_TRACKBAR, 0);
end;

class procedure TWin32WSTrackBarDark.DefaultWndHandler(
  const AWinControl: TWinControl; var AMessage);
var
  NMHdr: PNMHDR;
  NMCustomDraw: PNMCustomDraw;
begin
  with TLMessage(AMessage) do
    case Msg of
      CN_NOTIFY:
        begin
          NMHdr := PNMHDR(LParam);
          if NMHdr^.code = NM_CUSTOMDRAW then
          begin
            NMCustomDraw:= PNMCustomDraw(LParam);
            case NMCustomDraw^.dwDrawStage of
              CDDS_PREPAINT:
              begin
                Result := CDRF_NOTIFYITEMDRAW;
              end;
              CDDS_ITEMPREPAINT:
              begin
                case NMCustomDraw^.dwItemSpec of
                  TBCD_CHANNEL:
                    begin
                      Result:= CDRF_SKIPDEFAULT;
                      SelectObject(NMCustomDraw^.hdc, GetStockObject(DC_PEN));
                      SetDCPenColor(NMCustomDraw^.hdc, SysColor[COLOR_BTNSHADOW]);
                      SelectObject(NMCustomDraw^.hdc, GetStockObject(DC_BRUSH));
                      SetDCBrushColor(NMCustomDraw^.hdc, SysColor[COLOR_BTNFACE]);
                      with NMCustomDraw^.rc do
                        RoundRect(NMCustomDraw^.hdc, Left, Top, Right, Bottom, 6, 6);
                    end;
                  else begin
                    Result:= CDRF_DODEFAULT;
                  end;
                end;
              end;
            end;
          end;
        end
      else
        inherited DefaultWndHandler(AWinControl, AMessage);
    end;
end;

{ TWin32WSScrollBoxDark }

function ScrollBoxWindowProc(Window: HWND; Msg: UINT; wParam: Windows.WPARAM; lParam: Windows.LPARAM; uISubClass: UINT_PTR; dwRefData: DWORD_PTR): LRESULT; stdcall;
var
  DC: HDC;
  R, W: TRect;
  Delta: Integer;
begin
  Result:= DefSubclassProc(Window, Msg, WParam, LParam);

  if Msg = WM_NCPAINT then
  begin
    GetClientRect(Window, @R);
    MapWindowPoints(Window, 0, @R, 2);
    GetWindowRect(Window, @W);
    Delta:= Abs(W.Top - R.Top);

    DC:= GetWindowDC(Window);
    ExcludeClipRect(DC, Delta, Delta, W.Width - Delta, W.Height - Delta);
    SelectObject(DC, GetStockObject(DC_PEN));
    SelectObject(DC, GetStockObject(DC_BRUSH));
    SetDCPenColor(DC, SysColor[COLOR_BTNSHADOW]);
    SetDCBrushColor(DC, SysColor[COLOR_BTNHIGHLIGHT]);
    Rectangle(DC, 0, 0, W.Width, W.Height);
    ReleaseDC(Window, DC);
  end;
end;

class function TWin32WSScrollBoxDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  Result:= inherited CreateHandle(AWinControl, AParams);
  if not (csDesigning in AWinControl.ComponentState) then begin
    if TScrollBox(AWinControl).BorderStyle = bsSingle then begin
      SetWindowSubclass(Result, @ScrollBoxWindowProc, ID_SUB_SCROLLBOX, 0);
    end;
    EnableDarkStyle(Result);
  end;
end;

{ TWin32WSCustomGroupBoxDark }

class function TWin32WSCustomGroupBoxDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  PrepareDarkGroupedChildSizing(AWinControl);
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  InstallDarkGroupBoxWndProc(Result);
  EnableDarkStyle(Result);
  if (AWinControl is TCustomRadioGroup) or (AWinControl is TCustomCheckGroup) then
    PostMessage(Result, DARK_GROUPBOX_SYNC_CHILDREN_MSG, 0, 0);
end;

class function TWin32WSCustomGroupBoxDark.GetDefaultColor(
  const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  Result := DarkControlDefaultColor(ADefaultColorType);
end;

class procedure TWin32WSCustomGroupBoxDark.ShowHide(
  const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSButtonDark }

class function TWin32WSButtonDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  EnableDarkStyle(Result);
  InstallDarkButtonWndProc(Result);
end;

class procedure TWin32WSButtonDark.ShowHide(const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSBitBtnDark }

class function TWin32WSBitBtnDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  if not (csDesigning in AWinControl.ComponentState) then
  begin
    EnableDarkStyle(Result);
    InstallDarkButtonWndProc(Result);
  end;
end;

class procedure TWin32WSBitBtnDark.ShowHide(const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSCustomCheckBoxDark }

class function TWin32WSCustomCheckBoxDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  EnableDarkStyle(Result);
  if not IsDarkGroupedDesignItem(AWinControl) then
    InstallDarkCheckRadioWndProc(Result);
  PostDarkGroupedParentSync(AWinControl);
end;

class function TWin32WSCustomCheckBoxDark.GetDefaultColor(
  const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  Result := DarkControlDefaultColor(ADefaultColorType);
end;

class procedure TWin32WSCustomCheckBoxDark.ShowHide(
  const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSRadioButtonDark }

class function TWin32WSRadioButtonDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  EnableDarkStyle(Result);
  if not IsDarkGroupedDesignItem(AWinControl) then
    InstallDarkCheckRadioWndProc(Result);
  PostDarkGroupedParentSync(AWinControl);
end;

class function TWin32WSRadioButtonDark.GetDefaultColor(
  const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  Result := DarkControlDefaultColor(ADefaultColorType);
end;

class procedure TWin32WSRadioButtonDark.ShowHide(
  const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSCustomPageDark }

class function TWin32WSCustomPageDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  EnableDarkStyle(Result);
end;

class function TWin32WSCustomPageDark.GetDefaultColor(const AControl: TControl;
  const ADefaultColorType: TDefaultColorType): TColor;
begin
  Result := DarkControlDefaultColor(ADefaultColorType);
end;

class procedure TWin32WSCustomPageDark.ShowHide(
  const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSCustomTabControlDark }

class function TWin32WSCustomTabControlDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  SetDarkControlColors(AWinControl);
  Result := inherited CreateHandle(AWinControl, AParams);
  EnableDarkStyle(Result);
end;

class function TWin32WSCustomTabControlDark.GetDefaultColor(
  const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  Result := DarkControlDefaultColor(ADefaultColorType);
end;

class procedure TWin32WSCustomTabControlDark.ShowHide(
  const AWinControl: TWinControl);
begin
  DarkWin32ShowHide(AWinControl);
end;

{ TWin32WSPopupMenuDark }

class procedure TWin32WSPopupMenuDark.Popup(const APopupMenu: TPopupMenu;
  const X, Y: integer);
begin
  SetMenuBackground(APopupMenu.Handle);

  inherited Popup(APopupMenu, X, Y);
end;

{ TWin32WSWinControlDark }

class function TWin32WSWinControlDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
var
  P: TCreateParams;
begin
  P:= AParams;
  if not (csDesigning in AWinControl.ComponentState) then begin
    if (AWinControl is TCustomTreeView) then
    begin
      AWinControl.Color:= SysColor[COLOR_WINDOW];
      with TCustomTreeView(AWinControl) do begin
        if DrawControl.TreeViewExpandSignOverride then
          ExpandSignType:=DrawControl.TreeViewExpandSignValue;
        TreeLineColor:= SysColor[COLOR_GRAYTEXT];
        ExpandSignColor:= SysColor[COLOR_GRAYTEXT];
      end;
    end;
    P.ExStyle:= p.ExStyle and not WS_EX_CLIENTEDGE;
    if DrawControl.BorderStyleOverride then
      TWinControlDark(AWinControl).BorderStyle:= bsNone;
  end;

  Result:= inherited CreateHandle(AWinControl, P);

  if not (csDesigning in AWinControl.ComponentState) then begin
     EnableDarkStyle(Result);
  end;
end;

{ TWin32WSScrollBarDark }

procedure DrawDarkScrollBarArrow(ACanvas: TCanvas; const ARect: TRect;
  AVertical, AForward: Boolean);
var
  CenterX, CenterY, Size: Integer;
  Points: array[0..2] of TPoint;

  procedure SetPoint(AIndex, X, Y: Integer);
  begin
    Points[AIndex].X := X;
    Points[AIndex].Y := Y;
  end;

begin
  CenterX := (ARect.Left + ARect.Right) div 2;
  CenterY := (ARect.Top + ARect.Bottom) div 2;
  Size := Max(3, Min(ARect.Width, ARect.Height) div 4);

  if AVertical then
  begin
    if AForward then
    begin
      SetPoint(0, CenterX - Size, CenterY - Size div 2);
      SetPoint(1, CenterX + Size, CenterY - Size div 2);
      SetPoint(2, CenterX, CenterY + Size);
    end
    else
    begin
      SetPoint(0, CenterX - Size, CenterY + Size div 2);
      SetPoint(1, CenterX + Size, CenterY + Size div 2);
      SetPoint(2, CenterX, CenterY - Size);
    end;
  end
  else
  begin
    if AForward then
    begin
      SetPoint(0, CenterX - Size div 2, CenterY - Size);
      SetPoint(1, CenterX - Size div 2, CenterY + Size);
      SetPoint(2, CenterX + Size, CenterY);
    end
    else
    begin
      SetPoint(0, CenterX + Size div 2, CenterY - Size);
      SetPoint(1, CenterX + Size div 2, CenterY + Size);
      SetPoint(2, CenterX - Size, CenterY);
    end;
  end;

  ACanvas.Brush.Color := SysColor[COLOR_GRAYTEXT];
  ACanvas.Pen.Color := ACanvas.Brush.Color;
  ACanvas.Polygon(Points);
end;

procedure PaintDarkScrollBar(Window: HWND; DC: HDC);
const
  MinThumbSize = 10;
var
  Info: PWin32WindowInfo;
  R, FirstButtonRect, SecondButtonRect, TrackRect, ThumbRect: TRect;
  ACanvas: TCanvas;
  IsVertical: Boolean;
  ArrowLength, TrackLength, ThumbLength, ThumbTravel, ThumbOffset: Integer;
  MinScroll, MaxScroll, ScrollRange, PageSize, MaxPosition, PositionRange,
  ScrollPos: Integer;
begin
  GetClientRect(Window, @R);
  if (R.Width <= 0) or (R.Height <= 0) then
    Exit;

  IsVertical := (GetWindowLongPtr(Window, GWL_STYLE) and SBS_VERT) <> 0;
  Info := GetWin32WindowInfo(Window);
  if Assigned(Info) and (Info^.WinControl is TCustomScrollBar) then
  begin
    IsVertical := TCustomScrollBar(Info^.WinControl).Kind = sbVertical;
    MinScroll := TCustomScrollBar(Info^.WinControl).Min;
    MaxScroll := TCustomScrollBar(Info^.WinControl).Max;
    PageSize := TCustomScrollBar(Info^.WinControl).PageSize;
    ScrollPos := TCustomScrollBar(Info^.WinControl).Position;
  end
  else
  begin
    MinScroll := 0;
    MaxScroll := 100;
    PageSize := 10;
    ScrollPos := 0;
  end;

  if IsVertical then
  begin
    ArrowLength := Min(GetSystemMetrics(SM_CYVSCROLL), R.Height div 2);
    FirstButtonRect := Classes.Rect(R.Left, R.Top, R.Right, R.Top + ArrowLength);
    SecondButtonRect := Classes.Rect(R.Left, R.Bottom - ArrowLength, R.Right, R.Bottom);
    TrackRect := Classes.Rect(R.Left, FirstButtonRect.Bottom, R.Right, SecondButtonRect.Top);
    TrackLength := TrackRect.Height;
  end
  else
  begin
    ArrowLength := Min(GetSystemMetrics(SM_CXHSCROLL), R.Width div 2);
    FirstButtonRect := Classes.Rect(R.Left, R.Top, R.Left + ArrowLength, R.Bottom);
    SecondButtonRect := Classes.Rect(R.Right - ArrowLength, R.Top, R.Right, R.Bottom);
    TrackRect := Classes.Rect(FirstButtonRect.Right, R.Top, SecondButtonRect.Left, R.Bottom);
    TrackLength := TrackRect.Width;
  end;

  ScrollRange := Max(1, MaxScroll - MinScroll + 1);
  PageSize := Max(0, PageSize);
  if (PageSize > 0) and (TrackLength > 0) then
    ThumbLength := MulDiv(TrackLength, Min(PageSize, ScrollRange), ScrollRange)
  else
    ThumbLength := MinThumbSize;
  ThumbLength := Max(MinThumbSize, Min(TrackLength, ThumbLength));

  MaxPosition := MaxScroll - Max(PageSize - 1, 0);
  if MaxPosition < MinScroll then
    MaxPosition := MinScroll;
  ScrollPos := Max(MinScroll, Min(ScrollPos, MaxPosition));
  PositionRange := MaxPosition - MinScroll;
  ThumbTravel := Max(0, TrackLength - ThumbLength);
  if PositionRange > 0 then
    ThumbOffset := MulDiv(ScrollPos - MinScroll, ThumbTravel, PositionRange)
  else
    ThumbOffset := 0;

  if IsVertical then
    ThumbRect := Classes.Rect(TrackRect.Left, TrackRect.Top + ThumbOffset, TrackRect.Right,
      TrackRect.Top + ThumbOffset + ThumbLength)
  else
    ThumbRect := Classes.Rect(TrackRect.Left + ThumbOffset, TrackRect.Top,
      TrackRect.Left + ThumbOffset + ThumbLength, TrackRect.Bottom);

  ACanvas := TCanvas.Create;
  try
    ACanvas.Handle := DC;
    ACanvas.Brush.Color := SysColor[COLOR_BTNSHADOW];
    ACanvas.Pen.Color := ACanvas.Brush.Color;
    ACanvas.FillRect(R);

    ACanvas.Brush.Color := SysColor[COLOR_BTNFACE];
    ACanvas.FillRect(FirstButtonRect);
    ACanvas.FillRect(SecondButtonRect);

    ACanvas.Brush.Color := RGBToColor(77, 77, 77);
    ACanvas.Pen.Color := SysColor[COLOR_BTNHIGHLIGHT];
    ACanvas.Rectangle(ThumbRect);

    DrawDarkScrollBarArrow(ACanvas, FirstButtonRect, IsVertical, False);
    DrawDarkScrollBarArrow(ACanvas, SecondButtonRect, IsVertical, True);
  finally
    ACanvas.Handle := 0;
    ACanvas.Free;
  end;
end;

function ScrollBarDarkWndProc(Window: HWND; Msg: UINT; wParam: Windows.WPARAM;
  lParam: Windows.LPARAM; uISubClass: UINT_PTR; dwRefData: DWORD_PTR): LRESULT; stdcall;
var
  PS: TPaintStruct;
  DC: HDC;
begin
  case Msg of
    WM_ERASEBKGND:
      Exit(1);
    WM_PAINT:
      begin
        DC := BeginPaint(Window, @PS);
        try
          PaintDarkScrollBar(Window, DC);
        finally
          EndPaint(Window, @PS);
        end;
        Exit(0);
      end;
    WM_ENABLE, WM_SIZE, $00E0, $00E2, $00E6, $00E9:
      begin
        Result := DefSubclassProc(Window, Msg, WParam, LParam);
        InvalidateRect(Window, nil, False);
        Exit;
      end;
  end;

  Result := DefSubclassProc(Window, Msg, WParam, LParam);
end;

class function TWin32WSScrollBarDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  Result := inherited CreateHandle(AWinControl, AParams);
  SetWindowSubclass(Result, @ScrollBarDarkWndProc, ID_SUB_SCROLLBAR, 0);
  EnableDarkStyle(Result);
end;

{ TWin32WSCustomTreeViewDark }

class function TWin32WSCustomTreeViewDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  Result := TWin32WSWinControlDark.CreateHandle(AWinControl, AParams);
end;

{ TWin32WSCustomSplitterDark }

class function TWin32WSCustomSplitterDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  Result := TWin32WSWinControlDark.CreateHandle(AWinControl, AParams);
end;

{ TWin32WSCustomFormDark }

function FormWndProc2(Window: HWnd; Msg: UInt; WParam: Windows.WParam;
    LParam: Windows.LParam): LResult; stdcall;
var
  DC: HDC;
  R: TRect;
  Info: PWin32WindowInfo;
  Form: TCustomForm;
begin
  case Msg of
    WM_NCACTIVATE,
    WM_NCPAINT:
    begin
      Result:= CallWindowProc(CustomFormWndProc, Window, Msg, wParam, lParam);

      DC:= GetWindowDC(Window);
      R:= GetNonclientMenuBorderRect(Window);
      FillRect(DC, R, GetSysColorBrush(COLOR_WINDOW));
      ReleaseDC(Window, DC);
    end;
    WM_SHOWWINDOW:
    begin
      AllowDarkModeForWindow(Window, True);
      RefreshTitleBarThemeColor(Window);
      Result:= CallWindowProc(CustomFormWndProc, Window, Msg, wParam, lParam);
    end;
    WM_THEMECHANGED:
    begin
      Result:= CallWindowProc(CustomFormWndProc, Window, Msg, wParam, lParam);
      AllowDarkModeForWindow(Window, True);
      RefreshTitleBarThemeColor(Window);
      Info:= GetWin32WindowInfo(Window);
      if Assigned(Info) and Assigned(Info^.WinControl) and (Info^.WinControl is TCustomForm) then
      begin
        Form:= TCustomForm(Info^.WinControl);
        if Assigned(Form.Menu) then
        begin
          Form.Menu.OwnerDraw:= True;
          SetMenuBackground(GetMenu(Window));
          Form.Menu.OwnerDraw:= False;
        end;
      end;
      InvalidateRect(Window, nil, True);
    end
    else begin
      Result:= CallWindowProc(CustomFormWndProc, Window, Msg, wParam, lParam);
    end;
  end;
end;

class function TWin32WSCustomFormDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  if not (csDesigning in AWinControl.ComponentState) then begin
    AWinControl.DoubleBuffered:= True;
    AWinControl.Color:= SysColor[COLOR_BTNFACE];
    AWinControl.Brush.Color:= SysColor[COLOR_BTNFACE];
  end;

  Result:= inherited CreateHandle(AWinControl, AParams);

  if Result <> 0 then
  begin
    AllowDarkModeForWindow(Result, True);
    RefreshTitleBarThemeColor(Result);
  end;

  if not (csDesigning in AWinControl.ComponentState) then begin
    AWinControl.Color:= SysColor[COLOR_BTNFACE];
    AWinControl.Font.Color:= SysColor[COLOR_BTNTEXT];
  end;
end;

{ TWin32WSCustomListBoxDark }

function ListBoxWindowProc2(Window: HWND; Msg: UINT; wParam: Windows.WPARAM; lParam: Windows.LPARAM; uISubClass: UINT_PTR; dwRefData: DWORD_PTR): LRESULT; stdcall;
var
  PS: TPaintStruct;
begin
  if Msg = WM_PAINT then
  begin
    if SendMessage(Window, LB_GETCOUNT, 0, 0) = 0 then
    begin
      BeginPaint(Window, @ps);
      // ListBox:= TCustomListBox(GetWin32WindowInfo(Window)^.WinControl);
      // Windows.FillRect(DC, ps.rcPaint, ListBox.Brush.Reference.Handle);
      EndPaint(Window, @ps);
    end;
  end;
  Result:= DefSubclassProc(Window, Msg, WParam, LParam);
end;

class function TWin32WSCustomListBoxDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
var
  P: TCreateParams;
begin
  P:= AParams;
  if not (csDesigning in AWinControl.ComponentState) then begin
    P.ExStyle:= P.ExStyle and not WS_EX_CLIENTEDGE;
    if DrawControl.BorderStyleOverride then
      TCustomListBox(AWinControl).BorderStyle:= bsNone;
  end;

  Result:= inherited CreateHandle(AWinControl, P);

  if not (csDesigning in AWinControl.ComponentState) then begin
    EnableDarkStyle(Result);
    SetWindowSubclass(Result, @ListBoxWindowProc2, ID_SUB_LISTBOX, 0);
    TCustomListBox(AWinControl).Color:= SysColor[COLOR_WINDOW];
    AWinControl.Font.Color:= SysColor[COLOR_WINDOWTEXT];
  end;
end;

{ TWin32WSCustomListViewDark }

function ListViewWindowProc(Window: HWND; Msg: UINT; wParam: Windows.WPARAM; lParam: Windows.LPARAM; uISubClass: UINT_PTR; dwRefData: DWORD_PTR): LRESULT; stdcall;
var NMHdr: PNMHDR; NMCustomDraw: PNMCustomDraw;
begin
  If Msg = WM_NOTIFY then begin
    NMHdr := PNMHDR(LParam);
    if NMHdr^.code = NM_CUSTOMDRAW then begin
      NMCustomDraw:= PNMCustomDraw(LParam);
      case NMCustomDraw^.dwDrawStage of
        CDDS_PREPAINT:
        begin
          Result := CDRF_NOTIFYITEMDRAW;
          exit;
        end;
        CDDS_ITEMPREPAINT:
        begin
          SetTextColor(NMCustomDraw^.hdc , SysColor[COLOR_HIGHLIGHTTEXT]);
          Result := CDRF_NEWFONT;
          exit;
        end;
      end;
    end;
  end;
  Result := DefSubclassProc(Window, Msg, WParam, LParam);
end;

class function TWin32WSCustomListViewDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
var
  P: TCreateParams;
begin
  P:= AParams;
  P.ExStyle:= P.ExStyle and not WS_EX_CLIENTEDGE;
  if DrawControl.BorderStyleOverride then
    TCustomListView(AWinControl).BorderStyle:= bsNone;
  Result:= inherited CreateHandle(AWinControl, P);
  SetWindowSubclass(Result, @ListViewWindowProc, ID_SUB_LISTVIEW, 0);
  ListView_SetBkColor(Result, SysColor[COLOR_WINDOW]);
  ListView_SetTextBkColor(Result, SysColor[COLOR_WINDOW]);
  ListView_SetTextColor(Result, SysColor[COLOR_WINDOWTEXT]);
  EnableDarkStyle(Result);
end;

{ TWin32WSCustomEditDark }

class function TWin32WSCustomEditDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
var
  P: TCreateParams;
begin
  P := AParams;
  if not (csDesigning in AWinControl.ComponentState) then
  begin
    if DrawControl.BorderStyleOverride then
      TCustomEdit(AWinControl).BorderStyle := bsNone;
    P.ExStyle := P.ExStyle and not WS_EX_CLIENTEDGE;
    if IsSystemWindowColor(AWinControl.Color) then
      AWinControl.Color := SysColor[COLOR_WINDOW];
    AWinControl.Brush.Color := AWinControl.Color;
    if IsSystemTextColor(AWinControl.Font.Color) then
      AWinControl.Font.Color := SysColor[COLOR_WINDOWTEXT];
  end;

  Result := inherited CreateHandle(AWinControl, P);
  EnableDarkStyle(Result);
end;

class function TWin32WSCustomEditDark.GetDefaultColor(
  const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
begin
  Result := DarkWindowDefaultColor(ADefaultColorType);
end;

{ TWin32WSCustomMemoDark }

class function TWin32WSCustomMemoDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
var
  P: TCreateParams;
begin
  P:= AParams;

  if not (csDesigning in AWinControl.ComponentState) then begin
    if DrawControl.BorderStyleOverride then
      TCustomEdit(AWinControl).BorderStyle:= bsNone;
    P.ExStyle:= P.ExStyle and not WS_EX_CLIENTEDGE;
    AWinControl.Color:= SysColor[COLOR_WINDOW];
    AWinControl.Font.Color:= SysColor[COLOR_WINDOWTEXT];
  end;

  Result:= inherited CreateHandle(AWinControl, P);

  if not (csDesigning in AWinControl.ComponentState) then begin
    EnableDarkStyle(Result);
  end;
end;

{ TWin32WSCustomComboBoxDark }

procedure PaintDarkComboButton(Window: HWND; DC: HDC);
var
  R: TRect;
  LCanvas: TCanvas;
  ButtonWidth: Integer;
begin
  if not GetClientRect(Window, R) then
    Exit;

  ButtonWidth := GetSystemMetrics(SM_CXVSCROLL);
  R.Left := Max(R.Left, R.Right - ButtonWidth - 2);
  InflateRect(R, -1, -1);

  LCanvas := TCanvas.Create;
  try
    LCanvas.Handle := DC;
    LCanvas.Brush.Color := SysColor[COLOR_WINDOW];
    LCanvas.FillRect(R);
    LCanvas.Pen.Color := SysColor[COLOR_BTNHIGHLIGHT];
    LCanvas.FrameRect(R);
    DrawDarkScrollBarArrow(LCanvas, R, True, True);
  finally
    LCanvas.Handle := 0;
    LCanvas.Free;
  end;
end;

function ComboBoxWindowProc(Window:HWND; Msg:UINT; wParam:Windows.WPARAM;lparam:Windows.LPARAM;uISubClass : UINT_PTR;dwRefData:DWORD_PTR):LRESULT; stdcall;
var
  DC: HDC;
  ComboBox: TCustomComboBox;
begin
  case Msg of
    WM_CTLCOLORLISTBOX:
    begin
      ComboBox:= TCustomComboBox(GetWin32WindowInfo(Window)^.WinControl);
      DC:= HDC(wParam);
      SetControlColors(ComboBox, DC);
      Exit(LResult(GetControlColorBrush(ComboBox)));
    end;
    WM_PAINT:
    begin
      Result := DefSubclassProc(Window, Msg, wParam, lParam);
      DC := GetDC(Window);
      try
        PaintDarkComboButton(Window, DC);
      finally
        ReleaseDC(Window, DC);
      end;
      Exit;
    end;
    WM_PRINTCLIENT:
    begin
      Result := DefSubclassProc(Window, Msg, wParam, lParam);
      PaintDarkComboButton(Window, HDC(wParam));
      Exit;
    end;
  end;
  Result:= DefSubclassProc(Window, Msg, wParam, lParam);
end;

class function TWin32WSCustomComboBoxDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
var
  Info: TComboboxInfo;
begin
  if not (csDesigning in AWinControl.ComponentState) then begin
    AWinControl.Color:= SysColor[COLOR_BTNFACE];
    AWinControl.Font.Color:= SysColor[COLOR_BTNTEXT];
  end;

  Result:= inherited CreateHandle(AWinControl, AParams);

  Info.cbSize:= SizeOf(Info);
  if Win32Extra.GetComboBoxInfo(Result, @Info) then
  begin
    if Info.hwndList <> 0 then
      EnableDarkStyle(Info.hwndList);
    if Info.hwndItem <> 0 then
      EnableDarkStyle(Info.hwndItem);
  end;

  AllowDarkModeForWindow(Result, True);
  SendMessageW(Result, WM_THEMECHANGED, 0, 0);
  SetWindowSubclass(Result, @ComboBoxWindowProc, ID_SUB_COMBOBOX, 0);
end;

class function TWin32WSCustomComboBoxDark.GetDefaultColor(
  const AControl: TControl; const ADefaultColorType: TDefaultColorType): TColor;
const
  DefColors: array[TDefaultColorType] of TColor = (
  { dctBrush } clBtnFace,
  { dctFont  } clBtnText
  );
begin
  Result:= DefColors[ADefaultColorType];
end;

{ TWin32WSStatusBarDark }

function StatusBarWndProc(Window: HWND; Msg: UINT; wParam: Windows.WPARAM; lParam: Windows.LPARAM; uISubClass: UINT_PTR; dwRefData: DWORD_PTR): LRESULT; stdcall;
var
  DC: HDC;
  X: Integer;
  Index: Integer;
  PS: TPaintStruct;
  LCanvas: TCanvas;
  APanel: TStatusPanel;
  StatusBar: TStatusBar;
  Info: PWin32WindowInfo;
  Detail:TThemedElementDetails;
  Rect:trect;
  gripSize: TSize;
  TextCenter:integer;
begin
  Info:= GetWin32WindowInfo(Window);
  if (Info = nil) or (Info^.WinControl = nil) then
  begin
    Result:= CallDefaultWindowProc(Window, Msg, WParam, LParam);
    Exit;
  end;

  {if Msg = WM_ERASEBKGND then
  begin
    StatusBar:= TStatusBar(Info^.WinControl);
    TWin32WSStatusBar.DoUpdate(StatusBar);
  end;}

  if ((Msg = WM_PAINT) Or (Msg = WM_ERASEBKGND)) then
  begin
    StatusBar:= TStatusBar(Info^.WinControl);
    TWin32WSStatusBar.DoUpdate(StatusBar);

    {if Msg<>WM_ERASEBKGND then
      TWin32WSStatusBar.DoUpdate(StatusBar);
    Result:= WindowProc(Window, Msg, WParam, LParam);
    exit;}

    DC:= BeginPaint(Window, @ps);

    LCanvas:= TCanvas.Create;
    try
      LCanvas.Handle:= DC;
      LCanvas.Brush.Color:= SysColor[COLOR_BTNHIGHLIGHT];
      LCanvas.FillRect(ps.rcPaint);

      X:= 1;
      LCanvas.Font.PixelsPerInch := Info^.WinControl.Font.PixelsPerInch;
      LCanvas.Font := Info^.WinControl.Font;
      LCanvas.Font.Color:= SysColor[COLOR_BTNTEXT];
      LCanvas.Pen.Color:= SysColor[COLOR_GRAYTEXT];
      TextCenter:= (StatusBar.Height - LCanvas.TextHeight('Ag')) div 2;
      if StatusBar.SimplePanel then
         LCanvas.TextOut(X+3, TextCenter, StatusBar.SimpleText)
      else
      for Index:= 0 to StatusBar.Panels.Count - 1 do
      begin
        APanel:= StatusBar.Panels[Index];
        Rect:=StatusBar.ClientRect;
        if APanel.Width>0 then begin
          case APanel.Style of
            psText:
              LCanvas.TextOut(X+1, TextCenter, APanel.Text);
            psOwnerDraw:begin
              Rect.Left:=X;
              Rect.Right:=x+APanel.Width;
              if Assigned(StatusBar.OnDrawPanel) then
                StatusBar.OnDrawPanel(StatusBar, APanel, Rect);
            end;
          end;
          if Index<>(StatusBar.Panels.Count - 1)then begin
            X+= APanel.Width;
            LCanvas.Line(x-2, ps.rcPaint.Top+3, x-2, ps.rcPaint.Bottom-3);
          end;
        end;
      end;
      if StatusBar.SizeGrip then begin
        Rect:=StatusBar.ClientRect;
        Detail:=ThemeServices.GetElementDetails(tsGripper);
        GetThemePartSize(TWin32ThemeServices(ThemeServices).Theme[teStatus],
                         LCanvas.Handle, SP_GRIPPER, 0, @Rect, TS_DRAW, gripSize);
        Rect.Left:=Rect.Right-gripSize.cx;
        Rect.Top:=Rect.Bottom-gripSize.cy;
        ThemeServices.DrawElement(LCanvas.Handle,Detail,Rect);
      end;
    finally
      LCanvas.Handle:= 0;
      LCanvas.Free;
    end;
    EndPaint(Window, @ps);
    Result:= 0;
  end
  else
    Result:= DefSubclassProc(Window, Msg, WParam, LParam);
end;

class function TWin32WSStatusBarDark.CreateHandle(
  const AWinControl: TWinControl; const AParams: TCreateParams): HWND;
begin
  Result:= inherited CreateHandle(AWinControl, AParams);
  SetWindowSubclass(Result, @StatusBarWndProc, ID_SUB_STATUSBAR, 0);
end;

{
  Forward declared functions
}
function InterceptOpenThemeData(hwnd: hwnd; pszClassList: LPCWSTR): hTheme; stdcall; forward;
procedure DrawButton(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect; pClipRect: PRECT); forward;
procedure DrawEdit(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect; pClipRect: PRECT); forward;
procedure DrawReBar(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect; pClipRect: PRECT); forward;
procedure DrawTreeView(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect; pClipRect: PRECT); forward;


{
  Draws text using the color and font defined by the visual style
}
function DrawThemeTextDark(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; pszText: LPCWSTR; iCharCount: Integer;
  dwTextFlags, dwTextFlags2: DWORD; const pRect: TRect): HRESULT; stdcall;
function needMenuGrayText(iPartId, iStateId: Integer):Boolean;
begin
  case iPartId of
      MENU_POPUPITEM:Result:=(iStateId = MDS_PRESSED)or(iStateId = MDS_DISABLED);
    else
      Result:=(iStateId in [MBI_DISABLED,MBI_DISABLEDHOT,MBI_DISABLEDPUSHED])and(iPartId<>MENU_BARITEM);
  end;
end;
var
  OldColor: COLORREF;
begin
  OldColor:= GetTextColor(hdc);
  if (hTheme = Win32Theme.Theme[teToolTip]) then
    OldColor:= SysColor[COLOR_INFOTEXT]
  else if (hTheme = Win32Theme.Theme[teMenu]) then begin
    if needMenuGrayText(iPartId, iStateId) then
      OldColor:= SysColor[COLOR_GRAYTEXT]
    else
      OldColor:= SysColor[COLOR_BTNTEXT]
  end else if (hTheme <> Win32Theme.Theme[teButton]) then
    OldColor:= SysColor[COLOR_BTNTEXT];

  OldColor:= SetTextColor(hdc, OldColor);
  SetBkMode(hdc, TRANSPARENT);

  DrawTextExW(hdc, pszText, iCharCount, @pRect, dwTextFlags, nil);

  SetTextColor(hdc, OldColor);

  Result:= S_OK;
end;

{
  Draws the border and fill defined by the visual style for the specified control part
}
function DrawThemeBackgroundDark(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT): HRESULT; stdcall;
function needMenuHiglightBkg(iPartId, iStateId: Integer):Boolean;
begin
  case iPartId of
      MENU_POPUPITEM:Result:=iStateId = MDS_HOT;
    else
      Result:=(((iStateId = MDS_HOT)or(iStateId = MDS_PRESSED))and(iPartId<>MENU_BARBACKGROUND))or((iPartId=MENU_BARITEM)and(iStateId = MDS_CHECKED));
  end;
end;

var
  LRect: TRect;
  AColor: TColor;
  LCanvas: TCanvas;
  AStyle: TTextStyle;
begin
  if (hTheme = Win32Theme.Theme[teScrollBar]) then begin

  end else if (hTheme = Win32Theme.Theme[teHeader]) then begin
    if iPartId in [HP_HEADERITEM, HP_HEADERITEMRIGHT] then
    begin
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;
        AColor:= SysColor[COLOR_BTNFACE];

        if iStateId in [HIS_HOT, HIS_SORTEDHOT, HIS_ICONHOT, HIS_ICONSORTEDHOT] then
          FillGradient(hdc, Lighter(AColor, 174), Lighter(AColor, 166), pRect, GRADIENT_FILL_RECT_V)
        else
          FillGradient(hdc, Lighter(AColor, 124), Lighter(AColor, 116), pRect, GRADIENT_FILL_RECT_V);

        if (iPartId <> HP_HEADERITEMRIGHT) then
        begin
          LCanvas.Pen.Color:= Lighter(AColor, 104);
          LCanvas.Line(pRect.Right-1, pRect.Top, pRect.Right-1, pRect.Bottom);

          LCanvas.Pen.Color:= Lighter(AColor, 158);
          LCanvas.Line(pRect.Right - 2, pRect.Top, pRect.Right - 2, pRect.Bottom);
        end;
        // Top line
        LCanvas.Pen.Color:= Lighter(AColor, 164);
        LCanvas.Line(pRect.Left, pRect.Top, pRect.Right, pRect.Top);
        // Bottom line
        LCanvas.Pen.Color:= Darker(AColor, 140);
        LCanvas.Line(pRect.Left, pRect.Bottom - 1, pRect.Right, pRect.Bottom - 1);
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
    end;
  end else if (hTheme = Win32Theme.Theme[teListView]) then begin
    if iPartId in [HP_HEADERITEM, HP_HEADERITEMRIGHT] then
    begin
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;
        AColor:= {RGBToColor(95, 95, 95);} SysColor[COLOR_BTNFACE];

        if iStateId in [HIS_HOT, HIS_SORTEDHOT, HIS_ICONHOT, HIS_ICONSORTEDHOT] then
          FillGradient(hdc, Lighter(AColor, 174), Lighter(AColor, 166), pRect, GRADIENT_FILL_RECT_V)
        else
          FillGradient(hdc, Lighter(AColor, 124), Lighter(AColor, 116), pRect, GRADIENT_FILL_RECT_V);

        if (iPartId <> HP_HEADERITEMRIGHT) then
        begin
          LCanvas.Pen.Color:= Lighter(AColor, 101);
          LCanvas.Line(pRect.Right - 1, pRect.Top, pRect.Right - 1, pRect.Bottom);

          LCanvas.Pen.Color:= Lighter(AColor, 131);
          LCanvas.Line(pRect.Right - 2, pRect.Top, pRect.Right - 2, pRect.Bottom);
        end;
        // Top line
        LCanvas.Pen.Color:= Lighter(AColor, 131);
        LCanvas.Line(pRect.Left, pRect.Top, pRect.Right, pRect.Top);
        // Bottom line
        LCanvas.Pen.Color:= Darker(AColor, 140);
        LCanvas.Line(pRect.Left, pRect.Bottom - 1, pRect.Right, pRect.Bottom - 1);
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
    end else
    if (iPartId = 0) then begin   // The unpainted area of the header after the rightmost column
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;
        AColor:=SysColor[COLOR_BTNFACE];
        //FillGradient(hdc, Lighter(AColor, 124), Lighter(AColor, 116), pRect, GRADIENT_FILL_RECT_V);
        FillGradient(hdc, Lighter(AColor, 102), Lighter(AColor, 94), pRect, GRADIENT_FILL_RECT_V);
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
    end else
    if (iPartId = HP_HEADERSORTARROW) then begin  // This applies to the current sort column
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;
        LCanvas.Pen.Color:=RGBToColor(202, 202, 202);
        if iStateId = HSAS_SORTEDUP then begin;     // iStateId transports the SortDirection
            LCanvas.Line(pRect.Left+3, 4, pRect.Left+7, 0);
            LCanvas.Line(pRect.Left+6, 1, pRect.Left+10, 5);
        end
        else if iStateId = HSAS_SORTEDDOWN then begin;
            LCanvas.Line(pRect.Left+3, 1, pRect.Left+7, 5);
            LCanvas.Line(pRect.Left+6, 4, pRect.Left+10, 0);
        end;
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
    end;
  end else if (hTheme = Win32Theme.Theme[teMenu]) then begin
    if iPartId in [MENU_BARBACKGROUND, MENU_BARITEM, MENU_POPUPITEM, MENU_POPUPGUTTER,
                   MENU_POPUPSUBMENU, MENU_POPUPSEPARATOR, MENU_POPUPCHECK,
                   MENU_POPUPCHECKBACKGROUND] then begin
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;

        if not (iPartId in [MENU_POPUPSUBMENU, MENU_POPUPCHECK, MENU_POPUPCHECKBACKGROUND]) then
        begin
          if needMenuHiglightBkg(iPartId,iStateId) then
            LCanvas.Brush.Color:= SysColor[COLOR_MENUHILIGHT]
          else begin
            LCanvas.Brush.Color:= SysColor[COLOR_MENUBAR];//RGBToColor(45, 45, 45);
          end;
          LCanvas.FillRect(pRect);
        end;

        if iPartId = MENU_POPUPCHECK then
        begin
          AStyle:= LCanvas.TextStyle;
          AStyle.Layout:= tlCenter;
          AStyle.Alignment:= taCenter;
          LCanvas.Brush.Style:= bsClear;
          LCanvas.Font.Name:= 'Segoe MDL2 Assets';
          LCanvas.Font.Color:= SysColor[COLOR_MENUTEXT];//RGBToColor(212, 212, 212);
          LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_CHECKBOX_CHECKED, AStyle);
        end;

        if iPartId = MENU_POPUPSEPARATOR then
        begin
         LRect:= pRect;
         LCanvas.Pen.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(112, 112, 112);
         LRect.Top:= LRect.Top + (LRect.Height div 2);
         LRect.Bottom:= LRect.Top;

         LCanvas.Line(LRect);
        end;

        if (iPartId = MENU_POPUPCHECKBACKGROUND) then
        begin
          LRect:= pRect;
          InflateRect(LRect, -1, -1);
          LCanvas.Pen.Color:= SysColor[COLOR_MENU];//RGBToColor(45, 45, 45);
          LCanvas.Brush.Color:= SysColor[COLOR_MENUHILIGHT];//RGBToColor(81, 81, 81);
          LCanvas.RoundRect(LRect, 6, 6);
        end;

        if iPartId = MENU_POPUPSUBMENU then
        begin
          LCanvas.Brush.Style:= bsClear;
          LCanvas.Font.Name:= 'Segoe MDL2 Assets';
          LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(111, 111, 111);
          LCanvas.TextOut(pRect.Left, pRect.Top, MDL_MENU_SUBMENU);
        end;
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
    end;
  end else if (hTheme = Win32Theme.Theme[teToolBar]) then begin
    if iPartId in [TP_BUTTON, TP_SPLITBUTTON, TP_SPLITBUTTONDROPDOWN] then
    begin
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;
        AColor:= SysColor[COLOR_BTNFACE];

        if iStateId = TS_HOT then
          LCanvas.Brush.Color:= Lighter(AColor, 116)
        else if iStateId = TS_PRESSED then
          LCanvas.Brush.Color:= Darker(AColor, 116)
        else begin
          LCanvas.Brush.Color:= AColor;
        end;
        LCanvas.FillRect(pRect);

        if iStateId <> TS_NORMAL then begin
          if iStateId = TS_CHECKED then begin
            LRect:= pRect;
            InflateRect(LRect, -2, -2);
            LCanvas.Brush.Color:= Lighter(AColor, 146);
            LCanvas.FillRect(LRect);
          end;

          LCanvas.Pen.Color:= Darker(AColor, 140);
          LCanvas.RoundRect(pRect, 6, 6);

          LRect:= pRect;

          LCanvas.Pen.Color:= Lighter(AColor, 140);
          InflateRect(LRect, -1, -1);
          LCanvas.RoundRect(LRect, 6, 6);
        end;

      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;

    end
    else if iPartId in [TP_SEPARATOR, TP_SEPARATORVERT] then
    begin
      LCanvas:= TCanvas.Create;
      try
        LRect:= pRect;
        LCanvas.Handle:= hdc;
        LCanvas.Brush.Color:= SysColor[COLOR_BTNSHADOW];

        if (iPartId = TP_SEPARATOR) then
        begin
          if (LRect.Right - LRect.Left) > 4 then
          begin
            LRect.Left := (LRect.Left + LRect.Right) div 2 - 1;
            LRect.Right := LRect.Left + 1;
          end;
          LRect.Top:= LRect.Top + 2;
          LRect.Bottom:= LRect.Bottom - 2;
        end
        else begin
          if (LRect.Bottom - LRect.Top) > 4 then
          begin
            LRect.Top := (LRect.Top + LRect.Bottom) div 2 - 1;
            LRect.Bottom := LRect.Top + 1;
          end;
          LRect.Left:= LRect.Left + 2;
          LRect.Right:= LRect.Right - 2;
        end;

        LCanvas.FillRect(LRect);

      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;

    end;
    if iPartId = TP_SPLITBUTTONDROPDOWN then
    begin
      LCanvas:= TCanvas.Create;
      try
        LCanvas.Handle:= hdc;
        DrawUpDownArrow(hDC, LCanvas, pRect, udBottom);
      finally
        LCanvas.Handle:= 0;
        LCanvas.Free;
      end;
    end;
  end else if (hTheme = Win32Theme.Theme[teButton]) then
    DrawButton(hTheme, hdc, iPartId, iStateId, pRect, pClipRect)
  else if (hTheme = Win32Theme.Theme[teEdit]) then
    DrawEdit(hTheme,hdc,iPartId,iStateId,pRect,pClipRect)
  else if (hTheme = Win32Theme.Theme[teRebar]) then
    DrawRebar(hTheme,hdc,iPartId,iStateId,pRect,pClipRect)

  else if (hTheme = Win32Theme.Theme[teTreeview]) and DrawControl.CustomDrawTreeViews then
    DrawTreeView(hTheme,hdc,iPartId,iStateId,pRect,pClipRect)
  else
    TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
  exit(S_OK);
  TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
  Result:= S_OK;
end;

var
  __CreateWindowExW: function(dwExStyle: DWORD; lpClassName: LPCWSTR; lpWindowName: LPCWSTR; dwStyle: DWORD; X: longint; Y: longint; nWidth: longint; nHeight: longint; hWndParent: HWND; hMenu: HMENU; hInstance: HINST; lpParam: LPVOID): HWND; stdcall;

function _CreateWindowExW(dwExStyle: DWORD; lpClassName: LPCWSTR;
  lpWindowName: LPCWSTR; dwStyle: DWORD; X: longint; Y: longint;
  nWidth: longint; nHeight: longint; hWndParent: HWND; hMenu: HMENU;
  hInstance: HINST; lpParam: LPVOID): HWND; stdcall; forward;

procedure EnsureCreateWindowExWTrampoline;
var
  hModule: THandle;
begin
  if Assigned(__CreateWindowExW) and (Pointer(__CreateWindowExW) <> Pointer(@_CreateWindowExW)) then
    Exit;

  hModule:= GetModuleHandle(user32);
  if hModule <> 0 then
    Pointer(__CreateWindowExW):= GetProcAddress(hModule, 'CreateWindowExW');
end;

procedure HookCreateWindowExW(pFunction: PPointer);
var
  OldFunction: Pointer;
begin
  if not Assigned(pFunction) then
    Exit;

  if Pointer(pFunction^) = Pointer(@_CreateWindowExW) then
  begin
    EnsureCreateWindowExWTrampoline;
    Exit;
  end;

  OldFunction:= ReplaceImportFunction(pFunction, @_CreateWindowExW);
  if (OldFunction <> nil) and (OldFunction <> Pointer(@_CreateWindowExW)) then
    Pointer(__CreateWindowExW):= OldFunction;
  EnsureCreateWindowExWTrampoline;
end;

function _DrawEdge(hdc: HDC; var qrc: TRect; edge: UINT; grfFlags: UINT): BOOL; stdcall;
var
  Original: HGDIOBJ;
  ClientRect: TRect;
  ColorDark, ColorLight: TColorRef;

  procedure DrawLine(X1, Y1, X2, Y2: Integer);
  begin
    MoveToEx(hdc, X1, Y1, nil);
    LineTo(hdc, X2, Y2);
  end;

  procedure InternalDrawEdge(Outer: Boolean; const R: TRect);
  var
    X1, Y1, X2, Y2: Integer;
    ColorLeftTop, ColorRightBottom: TColor;
  begin
    X1:= R.Left;
    Y1:= R.Top;
    X2:= R.Right;
    Y2:= R.Bottom;

    ColorLeftTop:= clNone;
    ColorRightBottom:= clNone;

    if Outer then
    begin
      if Edge and BDR_RAISEDOUTER <> 0 then
      begin
        ColorLeftTop:= ColorLight;
        ColorRightBottom:= ColorDark;
      end
      else if Edge and BDR_SUNKENOUTER <> 0 then
      begin
        ColorLeftTop:= ColorDark;
        ColorRightBottom:= ColorLight;
      end;
    end
    else
    begin
      if Edge and BDR_RAISEDINNER <> 0 then
      begin
        ColorLeftTop:= ColorLight;
        ColorRightBottom:= ColorDark;
      end
      else if Edge and BDR_SUNKENINNER <> 0 then
      begin
        ColorLeftTop:= ColorDark;
        ColorRightBottom:= ColorLight;
      end;
    end;

    SetDCPenColor(hdc, ColorLeftTop);

    if grfFlags and BF_LEFT <> 0 then
      DrawLine(X1, Y1, X1, Y2);
    if grfFlags and BF_TOP <> 0 then
      DrawLine(X1, Y1, X2, Y1);

    SetDCPenColor(hdc, ColorRightBottom);

    if grfFlags and BF_RIGHT <> 0 then
      DrawLine(X2, Y1, X2, Y2);
    if grfFlags and BF_BOTTOM <> 0 then
      DrawLine(X1, Y2, X2, Y2);
  end;

begin
  Result:= False;
  if IsRectEmpty(qrc) then
    Exit;

  ClientRect:= qrc;
  Dec(ClientRect.Right, 1);
  Dec(ClientRect.Bottom, 1);
  Original:= SelectObject(hdc, GetStockObject(DC_PEN));
  try
    ColorDark:= SysColor[COLOR_BTNSHADOW];
    ColorLight:= SysColor[COLOR_BTNHIGHLIGHT];

    if Edge and (BDR_SUNKENOUTER or BDR_RAISEDOUTER) <> 0 then
    begin
      InternalDrawEdge(True, ClientRect);
    end;

    InflateRect(ClientRect, -1, -1);

    if Edge and (BDR_SUNKENINNER or BDR_RAISEDINNER) <> 0 then
    begin
      InternalDrawEdge(False, ClientRect);
      InflateRect(ClientRect, -1, -1);
    end;

    Inc(ClientRect.Right);
    Inc(ClientRect.Bottom);

    if grfFlags and BF_ADJUST <> 0 then
    begin
      qrc:= ClientRect;
    end;

    Result:= True;
  finally
    SelectObject(hdc, Original);
  end;
end;

{
  Retrieves the current color of the specified display element
}
function GetSysColorDark(nIndex: longint): DWORD; stdcall;
begin
  if (nIndex >= 0) and (nIndex <= COLOR_ENDCOLORS) then
    Result:= SysColor[nIndex]
  else begin
    Result:= 0;
  end;
end;

{
  Retrieves a handle identifying a logical brush that corresponds to the specified color index
}
function GetSysColorBrushDark(nIndex: longint): HBRUSH; stdcall;
begin
  if (nIndex >= 0) and (nIndex <= COLOR_ENDCOLORS) then
  begin
    if (SysColorBrush[nIndex] = 0) then
    begin
      SysColorBrush[nIndex]:= CreateSolidBrush(SysColor[nIndex]);
    end;
    Result:= SysColorBrush[nIndex];
  end
  else begin
    Result:= CreateSolidBrush(GetSysColorDark(nIndex));
  end;
end;

function _CreateWindowExW(dwExStyle: DWORD; lpClassName: LPCWSTR; lpWindowName: LPCWSTR; dwStyle: DWORD; X: longint; Y: longint; nWidth: longint; nHeight: longint; hWndParent: HWND; hMenu: HMENU; hInstance: HINST; lpParam: LPVOID): HWND; stdcall;
begin
  EnsureCreateWindowExWTrampoline;
  if Assigned(__CreateWindowExW) and (Pointer(__CreateWindowExW) <> Pointer(@_CreateWindowExW)) then
    Result:= __CreateWindowExW(dwExStyle, lpClassName, lpWindowName, dwStyle, X, Y, nWidth, nHeight, hWndParent, hMenu, hInstance, lpParam)
  else
    Result:= 0;
end;

function TaskDialogIndirectDark(const pTaskConfig: PTASKDIALOGCONFIG; pnButton: PInteger; pnRadioButton: PInteger; pfVerificationFlagChecked: PBOOL): HRESULT; stdcall;
const
  BTN_USER = $1000;
var
  Idx: Integer;
  Index: Integer;
  Button: TDialogButton;
  Buttons: TDialogButtons;
  DlgType: Integer = idDialogInfo;
begin
  with pTaskConfig^ do
  begin
    if (pszMainIcon = TD_INFORMATION_ICON) then
      DlgType:= idDialogInfo
    else if (pszMainIcon = TD_WARNING_ICON) then
      DlgType:= idDialogWarning
    else if (pszMainIcon = TD_ERROR_ICON) then
      DlgType:= idDialogError
    else if (pszMainIcon = TD_SHIELD_ICON) then
      DlgType:= idDialogShield
    else if (dwFlags and TDF_USE_HICON_MAIN <> 0) then
    begin
      if (hMainIcon = Windows.LoadIcon(0, IDI_QUESTION)) then
        DlgType:= idDialogConfirm;
    end;

    Buttons:= TDialogButtons.Create(TDialogButton);
    try
      for Index:= 0 to cButtons - 1 do
      begin
        Button:= Buttons.Add;
        Idx:= pButtons[Index].nButtonID;
        Button.ModalResult:= (Idx + BTN_USER);
        Button.Default:= (Idx = nDefaultButton);
        Button.Caption:= UTF8Encode(UnicodeString(pButtons[Index].pszButtonText));
      end;

      Result:= DefaultQuestionDialog(UTF8Encode(UnicodeString(pszWindowTitle)),
                                     UTF8Encode(UnicodeString(pszContent)), DlgType, Buttons, 0);

      if Assigned(pnButton) then
      begin
        if (Result < BTN_USER) then
          pnButton^:= Result
        else begin
          pnButton^:= Result - BTN_USER;
        end;
      end;
    finally
      Buttons.Free;
    end;
  end;
  Result:= S_OK;
end;

procedure SubClassUpDown;
var
  Window: HWND;
  CurrentWndProc: Windows.WNDPROC;
begin
  Window:= CreateWindowW(UPDOWN_CLASSW, nil, 0, 0, 0, 200, 20, 0, 0, HINSTANCE, nil);
  CurrentWndProc:= Windows.WNDPROC(GetClassLongPtr(Window, GCLP_WNDPROC));
  if Assigned(CurrentWndProc) and (Pointer(CurrentWndProc) <> Pointer(@UpDownWndProc)) then
  begin
    OldUpDownWndProc:= CurrentWndProc;
    SetClassLongPtr(Window, GCLP_WNDPROC, LONG_PTR(@UpDownWndProc));
  end;
  DestroyWindow(Window);
end;

procedure ScreenFormEvent(Self, Sender: TObject; Form: TCustomForm);
begin
  if Assigned(Form.Menu) then
  begin
    Form.Menu.OwnerDraw:= True;
    SetMenuBackground(GetMenu(Form.Handle));
    Form.Menu.OwnerDraw:= False;
  end;
end;

procedure DarkFormChanged(Form: TObject);
begin
  if not IsDarkModeEnabled then
    Exit;
  if Form is TForm then
    ScreenFormEvent(nil,nil,Form as TForm);
end;

procedure ApplyWin32MetaDarkStyle(const CS: TDSColors);
begin
  Initialize(CS);
  ApplyDarkStyle;
end;

{
  Override several widgetset controls
}
procedure ApplyDarkStyle;
var
  Handler: TMethod;
  Index: TThemedElement;
begin
  if not IsDarkModeEnabled then
    Exit;

  SubClassUpDown;

  OpenThemeData:= @InterceptOpenThemeData;

  DefBtnColors[dctFont]:= SysColor[COLOR_BTNTEXT];
  DefBtnColors[dctBrush]:= SysColor[COLOR_BTNFACE];

  Handler.Code:= @ScreenFormEvent;
  Screen.AddHandlerFormVisibleChanged(TScreenFormEvent(Handler), True);

  with TWinControl.Create(nil) do Free;
  RegisterWSComponent(TWinControl, TWin32WSWinControlDark);
  RegisterWSComponent(TCustomControl, TWin32WSWinControlDark);
  RegisterWSComponent(TToolWindow, TWin32WSWinControlDark);

  WSStdCtrls.RegisterCustomScrollBar;
  RegisterWSComponent(TCustomScrollBar, TWin32WSScrollBarDark);

  WSComCtrls.RegisterCustomTreeView;
  RegisterWSComponent(TCustomTreeView, TWin32WSCustomTreeViewDark);

  WSExtCtrls.RegisterCustomSplitter;
  RegisterWSComponent(TCustomSplitter, TWin32WSCustomSplitterDark);

  WSStdCtrls.RegisterCustomGroupBox;
  RegisterWSComponent(TCustomGroupBox, TWin32WSCustomGroupBoxDark);

  WSExtCtrls.RegisterCustomRadioGroup;
  RegisterWSComponent(TCustomRadioGroup, TWin32WSCustomRadioGroupDark);

  WSExtCtrls.RegisterCustomCheckGroup;
  RegisterWSComponent(TCustomCheckGroup, TWin32WSCustomCheckGroupDark);

  WSStdCtrls.RegisterCustomButton;
  RegisterWSComponent(TCustomButton, TWin32WSButtonDark);

  WSButtons.RegisterCustomBitBtn;
  RegisterWSComponent(TCustomBitBtn, TWin32WSBitBtnDark);

  WSStdCtrls.RegisterCustomCheckBox;
  RegisterWSComponent(TCustomCheckBox, TWin32WSCustomCheckBoxDark);

  WSStdCtrls.RegisterRadioButton;
  RegisterWSComponent(TRadioButton, TWin32WSRadioButtonDark);

  ComCtrls.RegisterCustomPage;
  RegisterWSComponent(TCustomPage, TWin32WSCustomPageDark);

  ComCtrls.RegisterCustomTabControl;
  RegisterWSComponent(TCustomTabControl, TWin32WSCustomTabControlDark);

  WSComCtrls.RegisterStatusBar;
  RegisterWSComponent(TStatusBar, TWin32WSStatusBarDark);

  WSStdCtrls.RegisterCustomComboBox;
  RegisterWSComponent(TCustomComboBox, TWin32WSCustomComboBoxDark);

  WSStdCtrls.RegisterCustomEdit;
  RegisterWSComponent(TCustomEdit, TWin32WSCustomEditDark);

  WSStdCtrls.RegisterCustomMemo;
  RegisterWSComponent(TCustomMemo, TWin32WSCustomMemoDark);

  WSStdCtrls.RegisterCustomListBox;
  RegisterWSComponent(TCustomListBox, TWin32WSCustomListBoxDark);

  WSComCtrls.RegisterCustomListView;
  RegisterWSComponent(TCustomListView, TWin32WSCustomListViewDark);

  WSForms.RegisterScrollingWinControl;

  WSForms.RegisterCustomForm;
  RegisterWSComponent(TCustomForm, TWin32WSCustomFormDark);

  WSMenus.RegisterMenu;
  WSMenus.RegisterPopupMenu;
  RegisterWSComponent(TPopupMenu, TWin32WSPopupMenuDark);

  WSForms.RegisterScrollBox;
  RegisterWSComponent(TScrollBox, TWin32WSScrollBoxDark);

  RegisterCustomTrackBar;
  RegisterWSComponent(TCustomTrackBar, TWin32WSTrackBarDark);

  DrawThemeText:= @DrawThemeTextDark;
  DrawThemeBackground:= @DrawThemeBackgroundDark;

  TaskDialogIndirect:= @TaskDialogIndirectDark;

  Win32Theme:= TWin32ThemeServices(ThemeServices);
end;

function FormWndProc(Window: HWnd; Msg: UInt; WParam: Windows.WParam;
    LParam: Windows.LParam): LResult; stdcall;
begin
  if Msg = WM_CREATE then
  begin
    AllowDarkModeForWindow(Window, True);
    RefreshTitleBarThemeColor(Window);
  end
  else if (Msg = WM_SETFONT) then
  begin
    Result:= DefWindowProcW(Window, Msg, WParam, LParam);
    Exit;
  end;
  Result:= DefWindowProcW(Window, Msg, WParam, LParam);
end;

procedure DrawCheckBox(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
  AStyle: TTextStyle;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= HDC;

    LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
    LCanvas.FillRect(pRect);

    AStyle:= LCanvas.TextStyle;
    AStyle.Layout:= tlCenter;
    AStyle.ShowPrefix:= True;

    // Fill checkbox rect
    LCanvas.Font.Name:= 'Segoe MDL2 Assets';
    LCanvas.Font.Color:= SysColor[COLOR_WINDOW];
    LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_CHECKBOX_FILLED, AStyle);

    // Draw checkbox border
    if iStateId in [CBS_UNCHECKEDHOT, CBS_MIXEDHOT, CBS_CHECKEDHOT] then
      LCanvas.Font.Color:= SysColor[COLOR_HIGHLIGHT]
    else begin
      LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(192, 192, 192);
    end;
    LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_CHECKBOX_OUTLINE, AStyle);

    // Draw checkbox state
    if iStateId in [CBS_MIXEDNORMAL, CBS_MIXEDHOT,
                    CBS_MIXEDPRESSED, CBS_MIXEDDISABLED] then
    begin
      LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(120, 120, 120);
      LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_CHECKBOX_GRAYED, AStyle);
    end
    else if iStateId in [CBS_CHECKEDNORMAL, CBS_CHECKEDHOT,
                         CBS_CHECKEDPRESSED, CBS_CHECKEDDISABLED] then
    begin
      LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(192, 192, 192);
      LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_CHECKBOX_CHECKED, AStyle);
    end;
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;

procedure DrawEdit(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= HDC;

    // Draw border
    LCanvas.Brush.Style:= bsSolid;

    case iStateId of
      ETS_NORMAL:LCanvas.Pen.Color:= SysColor[COLOR_GRAYTEXT];
      ETS_HOT,ETS_FOCUSED,ETS_SELECTED:LCanvas.Pen.Color:= SysColor[COLOR_BTNTEXT];
      ETS_DISABLED,ETS_READONLY:LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];
    end;
    LCanvas.RoundRect(pRect, 0, 0);
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;

procedure DrawReBar(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect; pClipRect: PRECT);
var
  LCanvas: TCanvas;
begin
  // Draw only background, need fix it
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= HDC;

    LCanvas.Brush.Style:= bsClear;
    LCanvas.Pen.Color:=SysColor[COLOR_BTNFACE];

    {case iStateId of
    end;}
    LCanvas.RoundRect(pRect, 0, 0);
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;


procedure DrawRadionButton(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
  AStyle: TTextStyle;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= hdc;

    LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
    LCanvas.FillRect(pRect);

    AStyle:= LCanvas.TextStyle;
    AStyle.Layout:= tlCenter;
    AStyle.ShowPrefix:= True;

    // Draw radio circle
    LCanvas.Font.Name:= 'Segoe MDL2 Assets';
    LCanvas.Font.Color:= SysColor[COLOR_WINDOW];
    LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_RADIO_FILLED, AStyle);

    // Draw radio button state
    if iStateId in [RBS_CHECKEDNORMAL, RBS_CHECKEDHOT,
                    RBS_CHECKEDPRESSED, RBS_CHECKEDDISABLED] then
    begin
      LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(192, 192, 192);
      LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_RADIO_CHECKED, AStyle );
    end;

    // Set outline circle color
    if iStateId in [RBS_UNCHECKEDPRESSED, RBS_CHECKEDPRESSED] then
      LCanvas.Font.Color:= SysColor[COLOR_HIGHLIGHT]//RGBToColor(83, 160, 237)
    else if iStateId in [RBS_UNCHECKEDHOT, RBS_CHECKEDHOT] then
      LCanvas.Font.Color:= SysColor[COLOR_HIGHLIGHT]
    else begin
      LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(192, 192, 192);
    end;
    // Draw outline circle
    LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, MDL_RADIO_OUTLINE, AStyle);
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;

procedure DrawGroupBox(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= HDC;

    // Draw border
    LCanvas.Brush.Style:= bsClear;
    LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];
    LCanvas.RoundRect(pRect, 10, 10);
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;

procedure DrawScrollBar(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
  AStyle: TTextStyle;
  BtnSym: string;
  grpRect: TRect; bIsHot, bDarkColors: Boolean;
  sb_bkgnd, sb_gripbg, sv_gripframe, sb_gripHot, sb_gripHotFrame, sb_ArrDisabled, sb_ArrHotBg, sb_ArrHot : TColor;
begin
  bDarkColors := not (SysColor[0] = 13158600);  // Determine whether SysColors 'DefaultDark' or 'DefaultWhite' are used
  if bDarkColors then begin
     sb_bkgnd   := SysColor[COLOR_BTNSHADOW];       sb_gripbg := RGBToColor(77, 77, 77);
     sb_gripHot := RGBToColor(88, 88, 88);          sb_gripHotFrame := SysColor[COLOR_GRAYTEXT];
     sb_ArrDisabled := RGBToColor(82, 82, 82);      sb_ArrHot := SysColor[COLOR_HIGHLIGHTTEXT];
     sb_ArrHotBg := SysColor[COLOR_SCROLLBAR];
  end else begin
    sb_bkgnd   := SysColor[COLOR_3DLIGHT];          sb_gripbg := RGBToColor(210, 210, 210); //SysColor[COLOR_SCROLLBAR];
    sb_gripHot := RGBToColor(188, 188, 188);        sb_gripHotFrame := SysColor[COLOR_GRAYTEXT];
    sb_ArrDisabled := SysColor[COLOR_ACTIVEBORDER]; sb_ArrHot := SysColor[COLOR_WINDOWTEXT];
    sb_ArrHotBg := RGBToColor(210, 210, 210);
  end;
  LCanvas:= TCanvas.Create;
  try
    bIsHot := False;
    LCanvas.Handle:= HDC;

    case iPartId of
      SBP_ARROWBTN:begin
        LCanvas.Brush.Color:= sb_bkgnd;
        if iStateId in [ABS_UPHOT,ABS_DOWNHOT, ABS_LEFTHOT,ABS_RIGHTHOT,
                        ABS_UPPRESSED,ABS_DOWNPRESSED, ABS_LEFTPRESSED,ABS_RIGHTPRESSED] then
            LCanvas.Brush.Color:= sb_ArrHotBg
        else
            LCanvas.Brush.Color:= sb_bkgnd;
        LCanvas.FillRect(pRect);      // Does mainly affect the background of the arrow btn area

        AStyle:= LCanvas.TextStyle;
        AStyle.Alignment:= taCenter;
        AStyle.Layout:= tlCenter;
        AStyle.ShowPrefix:= True;
        LCanvas.Font.Name:= 'Segoe MDL2 Assets';
        case iStateId of
          ABS_UPNORMAL,
          ABS_UPHOT,
          ABS_UPPRESSED,
          ABS_UPDISABLED: BtnSym:=MDL_SCROLLBOX_BTNUP;
          ABS_DOWNNORMAL,
          ABS_DOWNHOT,
          ABS_DOWNPRESSED,
          ABS_DOWNDISABLED: BtnSym:=MDL_SCROLLBOX_BTNDOWN;
          ABS_LEFTNORMAL,
          ABS_LEFTHOT,
          ABS_LEFTPRESSED,
          ABS_LEFTDISABLED: BtnSym:=MDL_SCROLLBOX_BTNLEFT;
          ABS_RIGHTNORMAL,
          ABS_RIGHTHOT,
          ABS_RIGHTPRESSED,
          ABS_RIGHTDISABLED: BtnSym:=MDL_SCROLLBOX_BTNRIGHT;
          ABS_UPHOVER: BtnSym:=MDL_SCROLLBOX_BTNUP;
          ABS_DOWNHOVER: BtnSym:=MDL_SCROLLBOX_BTNDOWN;
          ABS_LEFTHOVER: BtnSym:=MDL_SCROLLBOX_BTNLEFT;
          ABS_RIGHTHOVER: BtnSym:=MDL_SCROLLBOX_BTNRIGHT;
        end;

        if iStateId in [ABS_UPDISABLED,ABS_DOWNDISABLED,
                        ABS_LEFTDISABLED,ABS_RIGHTDISABLED] then
          LCanvas.Font.Color:= sb_ArrDisabled
        else if iStateId in [ABS_UPHOT,ABS_DOWNHOT,
                             ABS_LEFTHOT,ABS_RIGHTHOT,
                             ABS_UPPRESSED,ABS_DOWNPRESSED,
                             ABS_LEFTPRESSED,ABS_RIGHTPRESSED] then
          LCanvas.Font.Color:= sb_ArrHot
        else begin
          LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];//RGBToColor(192, 192, 192);
        end;
        LCanvas.TextRect(pRect, pRect.TopLeft.X, pRect.TopLeft.Y, BtnSym, AStyle);
      end;
      SBP_GRIPPERHORZ,SBP_GRIPPERVERT:begin
        if iStateId in [ABS_UPDISABLED,ABS_DOWNDISABLED,
                        ABS_LEFTDISABLED,ABS_RIGHTDISABLED] then
          LCanvas.Brush.Color:= SysColor[COLOR_WINDOW]
        else if iStateId in [ABS_UPHOT,ABS_DOWNHOT,
                             ABS_LEFTHOT,ABS_RIGHTHOT,
                             ABS_UPPRESSED,ABS_DOWNPRESSED,
                             ABS_LEFTPRESSED,ABS_RIGHTPRESSED] then
          LCanvas.Brush.Color:= SysColor[COLOR_HIGHLIGHT]
        else begin
          LCanvas.Brush.Color:= SysColor[COLOR_GRAYTEXT];
        end;
        LCanvas.Pen.Color:= LCanvas.Brush.Color;

        // --- Draw the inner gripper:
        LCanvas.Brush.Color:= sb_gripbg;
        if iStateId in [ABS_UPHOT,ABS_DOWNHOT, ABS_LEFTHOT,ABS_RIGHTHOT,
                       ABS_UPPRESSED,ABS_DOWNPRESSED, ABS_LEFTPRESSED,ABS_RIGHTPRESSED] then begin
           LCanvas.Brush.Color:= sb_gripHot;
           bIsHot := True;
        end;
        grpRect := pRect;
        if (iPartId = SBP_GRIPPERHORZ) then begin
           if ((pRect.Bottom - pRect.Top) > 17) then begin
              Inc(grpRect.Top, 3);
              Dec(grpRect.Bottom, 3);
           end;
        end else begin  // iPartId SBP_GRIPPERVERT
           if ((pRect.Right - pRect.Left) > 19) then begin
              Inc(grpRect.Left, 2);
              if bDarkColors then
                 Dec(grpRect.Right, 2);
           end;
        end;
        LCanvas.FillRect(grpRect);

        if bIsHot then begin
           LCanvas.Brush.Color:= sb_gripHotFrame;
           LCanvas.FrameRect(grpRect);
        end;
      end;
      else begin
        LCanvas.Brush.Color:= sb_bkgnd;
        LCanvas.Pen.Color:=LCanvas.Brush.Color;
        LCanvas.FillRect(pRect);
      end;

    end;


  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;

procedure DrawPushButton(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= HDC;

    LCanvas.Brush.Style:= bsClear;

    if iStateId in [PBS_NORMAL,PBS_DEFAULTED,PBS_DEFAULTED_ANIMATING] then begin
      LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
      LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];
    end else if iStateId in [PBS_HOT] then begin
      LCanvas.Brush.Color:= SysColor[COLOR_BTNHIGHLIGHT];
      LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];
    end else if iStateId in [PBS_PRESSED] then begin
      LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
      LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];
    end else begin
      LCanvas.Brush.Color:= SysColor[COLOR_3DDKSHADOW];
      LCanvas.Pen.Color:= SysColor[COLOR_BTNHIGHLIGHT];
    end;

    LCanvas.RoundRect(pRect, 10, 10);
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;


procedure DrawButton(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
begin
  case iPartId of
    BP_PUSHBUTTON: if DrawControl.CustomDrawPushButtons then
                     DrawPushButton(hTheme, hdc, iPartId, iStateId, pRect, pClipRect)
                   else
                     TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
    BP_RADIOBUTTON: DrawRadionButton(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
    BP_CHECKBOX: DrawCheckBox(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
    BP_GROUPBOX: DrawGroupBox(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
  end;
end;

procedure DrawComboBox(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  LCanvas: TCanvas;
  AStyle: TTextStyle;
  BtnSym: string;
  r:TRect;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= HDC;

    case iPartId of
      CP_BORDER:begin
        LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
        LCanvas.FillRect(pRect);

        if iStateId in [CBXS_DISABLED] then begin
          LCanvas.Brush.Color:= SysColor[COLOR_WINDOW]
        end
        else if iStateId in [CBXS_HOT] then begin
          LCanvas.Brush.Color:= Darker(SysColor[COLOR_HIGHLIGHT],150)
        end
        else begin
          LCanvas.Brush.Color:= SysColor[COLOR_WINDOW]
        end;
        LCanvas.FrameRect(pRect);
      end;

      CP_DROPDOWNBUTTON,CP_DROPDOWNBUTTONRIGHT,CP_DROPDOWNBUTTONLEFT:begin

        AStyle:= LCanvas.TextStyle;
        AStyle.Alignment:= taCenter;
        AStyle.Layout:= tlCenter;
        AStyle.ShowPrefix:= True;
        LCanvas.Font.Name:= 'Segoe MDL2 Assets';
        BtnSym:=MDL_COMBOBOX_BTNDOWN;


        if iStateId in [CBXS_DISABLED] then begin
          LCanvas.Font.Color:= SysColor[COLOR_WINDOW];
          LCanvas.Brush.Color:= SysColor[COLOR_WINDOW]
        end
        else if iStateId in [CBXS_HOT] then begin
          LCanvas.Font.Color:= SysColor[COLOR_HIGHLIGHT];
          LCanvas.Brush.Color:= Darker(SysColor[COLOR_HIGHLIGHT],150)
        end
        else begin
          LCanvas.Font.Color:= SysColor[COLOR_GRAYTEXT];
          LCanvas.Brush.Color:= SysColor[COLOR_WINDOW]
        end;
        r:=pRect;
        InflateRect(r,-1,-1);
        LCanvas.FillRect(r);
        LCanvas.TextRect(r, pRect.TopLeft.X, pRect.TopLeft.Y, BtnSym, AStyle);
      end;
      {else begin
        LCanvas.Brush.Color:= SysColor[COLOR_BTNFACE];
        LCanvas.Pen.Color:=LCanvas.Brush.Color;
        LCanvas.FillRect(pRect);
      end;}

    end;


  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;



procedure DrawTabControl(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
var
  ARect: TRect;
  AColor: TColor;
  ALight: TColor;
  LCanvas: TCanvas;
begin
  LCanvas:= TCanvas.Create;
  try
    LCanvas.Handle:= hdc;

    AColor:= SysColor[COLOR_BTNFACE];
    ALight:= Lighter(AColor, 160);

    case iPartId of
      TABP_TOPTABITEM,
      TABP_TOPTABITEMLEFTEDGE,
      TABP_TOPTABITEMBOTHEDGE,
      TABP_TOPTABITEMRIGHTEDGE:
      begin
        ARect:= pRect;
        // Fill tab inside
        if (iStateId <> TIS_SELECTED) then
        begin
          if iStateId <> TIS_HOT then
            LCanvas.Brush.Color:= Lighter(AColor, 117)
          else begin
            LCanvas.Brush.Color:= Lighter(AColor, 200);
          end;
        end
        else begin
          Dec(ARect.Bottom);
          InflateRect(ARect, -1, -1);
          LCanvas.Brush.Color:= Lighter(AColor, 176);
        end;
        LCanvas.FillRect(ARect);
        LCanvas.Pen.Color:= ALight;

        if iPartId in [TABP_TOPTABITEMLEFTEDGE, TABP_TOPTABITEMBOTHEDGE] then
        begin
          // Draw left border
          LCanvas.Line(pRect.Left, pRect.Top, pRect.Left, pRect.Bottom);
        end;

        if (iStateId <> TIS_SELECTED) then
        begin
          // Draw right border
          LCanvas.Line(pRect.Right - 1, pRect.Top, pRect.Right - 1, pRect.Bottom)
        end
        else begin
          // Draw left border
          if (iPartId = TABP_TOPTABITEM) then
          begin
            LCanvas.Line(pRect.Left, pRect.Top, pRect.Left, pRect.Bottom - 1);
          end;
          // Draw right border
          LCanvas.Line(pRect.Right - 1, pRect.Top, pRect.Right - 1, pRect.Bottom - 1);
        end;
        // Draw top border
        LCanvas.Line(pRect.Left, pRect.Top, pRect.Right, pRect.Top);
      end;
      TABP_PANE:
      begin
        // Draw tab pane border
        LCanvas.Brush.Color:= AColor;
        LCanvas.Pen.Color:= ALight;
        LCanvas.Rectangle(pRect);
      end;
    end;
  finally
    LCanvas.Handle:= 0;
    LCanvas.Free;
  end;
end;

procedure DrawProgressBar(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
begin
  if not (iPartId in [PP_TRANSPARENTBAR, PP_TRANSPARENTBARVERT]) then
    TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect)
  else begin
    SelectObject(hdc, GetStockObject(DC_PEN));
    SetDCPenColor(hdc, SysColor[COLOR_BTNSHADOW]);
    SelectObject(hdc, GetStockObject(DC_BRUSH));
    SetDCBrushColor(hdc, SysColor[COLOR_BTNFACE]);
    with pRect do Rectangle(hdc, Left, Top, Right, Bottom);
  end;
end;

procedure DrawTreeView(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
begin
  if (iPartId = TVP_TREEITEM) and (iStateId in [TREIS_SELECTEDNOTFOCUS,TREIS_SELECTED]) then begin
    SelectObject(hdc, GetStockObject(DC_PEN));
    SetDCPenColor(hdc, SysColor[COLOR_BTNSHADOW]);
    SelectObject(hdc, GetStockObject(DC_BRUSH));
    if DrawControl.TreeViewDisableHideSelection then
      if iStateId=TREIS_SELECTEDNOTFOCUS then
        iStateId:=TREIS_SELECTED;
    case iStateId of
      TREIS_SELECTEDNOTFOCUS:SetDCBrushColor(hdc, SysColor[COLOR_BTNHIGHLIGHT]);
              TREIS_SELECTED:SetDCBrushColor(hdc, Lighter(SysColor[COLOR_BTNHIGHLIGHT], 146));
    end;
    with pRect do Rectangle(hdc, Left, Top, Right, Bottom);
  end else
    TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect)
end;

procedure DrawListViewHeader(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pRect: TRect;
  pClipRect: PRECT);
begin
  DrawThemeBackgroundDark(Win32Theme.Theme[teListView], hdc, iPartId, iStateId, pRect, pClipRect);
end;
function InterceptOpenNCThemeData(hwnd: hwnd; pszClassList: LPCWSTR): hTheme; stdcall;
begin
  result:=InterceptOpenThemeData(hwnd,pszClassList);
  hwnd:=hwnd;
end;

function InterceptOpenThemeData(hwnd: hwnd; pszClassList: LPCWSTR): hTheme; stdcall;
var
  P: LONG_PTR;
begin
  if (hwnd <> 0) then
  begin
    P:= GetWindowLongPtr(hwnd, GWL_EXSTYLE);

    if ((P and WS_EX_CONTEXTHELP = 0) or (lstrcmpiW(pszClassList, VSCLASS_MONTHCAL) = 0))
       and (lstrcmpiW(pszClassList, VSCLASS_TAB) <> 0)
       and not ShouldForceDarkThemeClass(pszClassList) then
    begin
      Result:= TrampolineOpenThemeData(hwnd, pszClassList);
      Exit;
    end;
  end;

  if lstrcmpiW(pszClassList, VSCLASS_TAB) = 0 then
  begin
    AllowDarkStyle(hwnd);
    pszClassList:= PWideChar(VSCLASS_DARK_TAB);
  end
  else if lstrcmpiW(pszClassList, VSCLASS_BUTTON) = 0 then
  begin
    AllowDarkStyle(hwnd);
    pszClassList:= PWideChar(VSCLASS_DARK_BUTTON);
  end
  else if lstrcmpiW(pszClassList, VSCLASS_EDIT) = 0 then
  begin
    AllowDarkStyle(hwnd);
    pszClassList:= PWideChar(VSCLASS_DARK_EDIT);
  end
  else if lstrcmpiW(pszClassList, VSCLASS_COMBOBOX) = 0 then
  begin
    AllowDarkStyle(hwnd);
    pszClassList:= PWideChar(VSCLASS_DARK_COMBOBOX);
  end

  else if lstrcmpiW(pszClassList, 'ListView') = 0 then
  begin
    ListView_SetBkColor(hwnd, SysColor[COLOR_WINDOW]);
    ListView_SetTextBkColor(hwnd, SysColor[COLOR_WINDOW]);
    ListView_SetTextColor(hwnd, SysColor[COLOR_WINDOWTEXT]);
  end

  else if lstrcmpiW(pszClassList, VSCLASS_SCROLLBAR) = 0 then
  begin
    AllowDarkStyle(hwnd);
    pszClassList:= PWideChar(VSCLASS_DARK_SCROLLBAR);
  end;

  Result:= TrampolineOpenThemeData(hwnd, pszClassList);
  ThemeClass.Insert(Result, pszClassList);
  if hwnd <> 0 then
    ThemeWindow.Insert(Result, hwnd);
end;

function InterceptDrawThemeText(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; pszText: LPCWSTR; iCharCount: Integer;
  dwTextFlags, dwTextFlags2: DWORD; const pRect: TRect): HRESULT; stdcall;
var
  OldColor: COLORREF;
  ClassName: LPCWSTR;

  function ControlFromDC: TWinControl;
  var
    Window: HWND;
    Info: PWin32WindowInfo;
  begin
    Result := nil;
    Window := WindowFromDC(hdc);
    if Window = 0 then
      Exit;

    Info := GetWin32WindowInfo(Window);
    if Assigned(Info) then
      Result := Info^.WinControl;

    if Result = nil then
      Result := TWinControl(GetProp(Window, PChar('WinControl')));
  end;

  function ControlFromTheme: TWinControl;
  var
    Window: HWND;
    Info: PWin32WindowInfo;
  begin
    Result := nil;
    if not Assigned(ThemeWindow) then
      Exit;
    if not ThemeWindow.TryGetValue(hTheme, Window) then
      Exit;

    Info := GetWin32WindowInfo(Window);
    if Assigned(Info) then
      Result := Info^.WinControl;

    if Result = nil then
      Result := TWinControl(GetProp(Window, PChar('WinControl')));
  end;

  function ThemedButtonTextColor(ACurrentColor: COLORREF): COLORREF;
  var
    Control: TWinControl;
    FontColor: TColor;
  begin
    if ((iPartId = BP_CHECKBOX) and
        (iStateId in [CBS_UNCHECKEDDISABLED, CBS_CHECKEDDISABLED, CBS_MIXEDDISABLED])) or
       ((iPartId = BP_RADIOBUTTON) and
        (iStateId in [RBS_UNCHECKEDDISABLED, RBS_CHECKEDDISABLED])) or
       ((iPartId = BP_GROUPBOX) and (iStateId = GBS_DISABLED)) or
       ((iPartId = BP_PUSHBUTTON) and (iStateId = PBS_DISABLED)) then
      Exit(SysColor[COLOR_GRAYTEXT]);

    if iPartId in [BP_CHECKBOX, BP_RADIOBUTTON, BP_GROUPBOX] then
    begin
      Control := ControlFromTheme;
      if Control = nil then
        Control := ControlFromDC;
      if Control <> nil then
      begin
        FontColor := Control.Font.Color;
        if IsSystemTextColor(FontColor) then
          FontColor := Control.GetDefaultColor(dctFont);
        if FontColor <> clDefault then
          Exit(ColorToRGB(FontColor));
      end;

      Exit(SysColor[COLOR_BTNTEXT]);
    end;

    Result := ACurrentColor;
  end;
begin
  OldColor:= GetTextColor(hdc);
  if Assigned(ThemeClass) then
    if ThemeClass.TryGetValue(hTheme, ClassName) then
    begin
      if SameText(ClassName, VSCLASS_DARK_COMBOBOX) or SameText(ClassName, VSCLASS_DARK_EDIT) then
      begin
        Result:= TrampolineDrawThemeText(hTheme, hdc, iPartId, iStateId, pszText, iCharCount, dwTextFlags, dwTextFlags2, pRect);
        Exit;
      end;

      if SameText(ClassName, VSCLASS_TOOLTIP) then
        OldColor:= SysColor[COLOR_INFOTEXT]
      else if not SameText(ClassName, VSCLASS_DARK_BUTTON) then begin
        OldColor:= SysColor[COLOR_BTNTEXT];
      end;

      if SameText(ClassName, VSCLASS_DARK_BUTTON) then
        OldColor := ThemedButtonTextColor(OldColor);

      OldColor:= SetTextColor(hdc, OldColor);
      SetBkMode(hdc, TRANSPARENT);

      DrawTextExW(hdc, pszText, iCharCount, @pRect, dwTextFlags, nil);

      SetTextColor(hdc, OldColor);

      Exit(S_OK);
  end;
  Result:= TrampolineDrawThemeText(hTheme, hdc, iPartId, iStateId, pszText, iCharCount, dwTextFlags, dwTextFlags2, pRect);
end;

function InterceptDrawThemeBackground(hTheme: hTheme; hdc: hdc; iPartId, iStateId: Integer; const pRect: TRect;
    pClipRect: Pointer): HRESULT; stdcall;
var
  Index: Integer;
  ClassName: LPCWSTR;
begin
  if assigned(ThemeClass)then
    if ThemeClass.TryGetValue(hTheme, ClassName) then
    begin
      Index:= SaveDC(hdc);
      try
        if (SameText(ClassName, VSCLASS_SCROLLBAR))then
        begin
          if DrawControl.CustomDrawScrollbars then
            DrawScrollBar(hTheme, hdc, iPartId, iStateId, pRect, pClipRect)
          else begin
            hTheme:=TrampolineOpenThemeData(0, VSCLASS_DARK_SCROLLBAR);
            Result:= TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
          end;
        end
        else if (SameText(ClassName, VSCLASS_DARK_SCROLLBAR))and DrawControl.CustomDrawScrollbars then
        begin
          DrawScrollBar(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end
        else if (SameText(ClassName,VSCLASS_DARK_COMBOBOX))and DrawControl.CustomDrawComboBoxs then
        begin
          DrawComboBox(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end
        else if SameText(ClassName, VSCLASS_DARK_BUTTON) then
        begin
          DrawButton(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end
        else if SameText(ClassName, VSCLASS_DARK_TAB) then
        begin
          DrawTabControl(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end
        else if SameText(ClassName, VSCLASS_PROGRESS) or SameText(ClassName, VSCLASS_PROGRESS_INDER) then
        begin
          DrawProgressBar(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end
        else if SameText(ClassName, VSCLASS_DARK_HEADER) then
        begin
          DrawListViewHeader(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end
        else begin
          Result:= TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
        end;
      finally
        RestoreDC(hdc, Index);
      end;
      Exit(S_OK);
    end;
  Result:= TrampolineDrawThemeBackground(hTheme, hdc, iPartId, iStateId, pRect, pClipRect);
end;

function DrawThemeEdgeDark(hTheme: HTHEME; hdc: HDC; iPartId, iStateId: Integer; const pDestRect: TRect; uEdge,
  uFlags: UINT; pContentRect: PRECT): HRESULT; stdcall;
var
  ARect: TRect;
begin
  ARect:= pDestRect;
  _DrawEdge(hdc, ARect, uEdge, uFlags);
  if (uFlags and DFCS_ADJUSTRECT <> 0) and (pContentRect <> nil) then
    pContentRect^ := ARect;
  Result:= S_OK;
end;

function GetThemeSysColorDark(hTheme: HTHEME; iColorId: Integer): COLORREF; stdcall;
begin
  Result:= GetSysColor(iColorId);
end;

function GetThemeSysColorBrushDark(hTheme: HTHEME; iColorId: Integer): HBRUSH; stdcall;
begin
  Result:= GetSysColorBrush(iColorId);
end;

var
  DeleteObjectOld: function(ho: HGDIOBJ): WINBOOL; stdcall;

function __DeleteObject(ho: HGDIOBJ): WINBOOL; stdcall;
var
  Index: Integer;
begin
  for Index:= 0 to High(SysColorBrush) do
  begin
    if SysColorBrush[Index] = ho then Exit(True);
  end;
  Result:= DeleteObjectOld(ho);
end;

procedure InitializeColors(const CS:TDSColors);
begin
  SysColor:=CS.SysColor;
  DrawControl:=CS.DrawControl;
end;

procedure SetColorsScheme(Scheme:TDSColors);
var
  Index: Integer;
begin
  for Index:= 0 to High(SysColorBrush) do
    SysColorBrush[Index] := 0;
  SysColor:=Scheme.SysColor;
end;

function WinRegister(ClassName: PWideChar): Boolean;
var
  WindowClassW: WndClassW;
begin
  ZeroMemory(@WindowClassW, SizeOf(WndClassW));
  with WindowClassW do
  begin
    Style := CS_DBLCLKS;
    LPFnWndProc := @FormWndProc;
    hInstance := System.HInstance;
    hIcon := Windows.LoadIcon(MainInstance, 'MAINICON');
    if hIcon = 0 then
     hIcon := Windows.LoadIcon(0, IDI_APPLICATION);
    hCursor := Windows.LoadCursor(0, IDC_ARROW);
    LPSzClassName := ClassName;
  end;
  Result := Windows.RegisterClassW(@WindowClassW) <> 0;
end;

function FindIATEntry(AddrVA: Pointer): Pointer;
begin
  if AddrVA = nil then Exit(nil);
  Result := Pointer(
    {$IFDEF CPUX64}
    // RIP
    PByte(AddrVA) + 6 +
    {$ENDIF}
    // IAT gate
    PCardinal(PByte(AddrVA) + 2)^);
end;

procedure Initialize(const CS:TDSColors);
var
  hModule, hUxTheme: THandle;
  pLibrary, pFunction: PPointer;
  pImpDesc: PIMAGE_DELAYLOAD_DESCRIPTOR;
begin
  if not IsDarkModeEnabled then
    Exit;

  if g_buildNumber>=26100{24H2} then
    VSCLASS_DARK_TAB:=VSCLASS_DARK_TAB2
  else
    VSCLASS_DARK_TAB:=VSCLASS_DARK_TAB1;

  InitializeColors(CS);

  ThemeClass:= TThemeClassMap.Create;
  ThemeWindow:= TThemeWindowMap.Create;

  hModule:= GetModuleHandle(gdi32);
  Pointer(DeleteObjectOld):= GetProcAddress(hModule, 'DeleteObject');

  hModule:= GetModuleHandle(comctl32);
  Pointer(DefSubclassProc):= GetProcAddress(hModule, 'DefSubclassProc');
  Pointer(SetWindowSubclass):= GetProcAddress(hModule, 'SetWindowSubclass');

  // Override several system functions
  pLibrary:= FindImportLibrary(MainInstance, user32);
  if Assigned(pLibrary) then
  begin
    hModule:= GetModuleHandle(user32);
    pFunction:= FindImportFunction(pLibrary, GetProcAddress(hModule, 'CreateWindowExW'));
    // UPX purpose
    if pFunction=nil then
      pFunction := FindIATEntry(@Windows.CreateWindowExW);
    HookCreateWindowExW(pFunction);
    pFunction:= FindImportFunction(pLibrary, GetProcAddress(hModule, 'DrawEdge'));
    // UPX purpose
    if pFunction=nil then
      pFunction := FindIATEntry(@Windows.DrawEdge);
    if Assigned(pFunction) then
    begin
      ReplaceImportFunction(pFunction, @_DrawEdge);
    end;
    pFunction:= FindImportFunction(pLibrary, GetProcAddress(hModule, 'GetSysColor'));
    // UPX purpose
    if pFunction=nil then
      pFunction := FindIATEntry(@Windows.GetSysColor);
    if Assigned(pFunction) then
    begin
      ReplaceImportFunction(pFunction, @GetSysColorDark);
    end;
    pFunction:= FindImportFunction(pLibrary, GetProcAddress(hModule, 'GetSysColorBrush'));
    // UPX purpose
    if pFunction=nil then
      pFunction := FindIATEntry(@Windows.GetSysColorBrush);
    if Assigned(pFunction) then
    begin
      ReplaceImportFunction(pFunction, @GetSysColorBrushDark);
    end;
  end
  else
  begin
    // UPX purpose
    pFunction := FindIATEntry(@Windows.CreateWindowExW);
    HookCreateWindowExW(pFunction);
    pFunction := FindIATEntry(@Windows.DrawEdge);
    if Assigned(pFunction) then
      ReplaceImportFunction(pFunction, @_DrawEdge);
    pFunction := FindIATEntry(@Windows.GetSysColor);
    if Assigned(pFunction) then
      ReplaceImportFunction(pFunction, @GetSysColorDark);
    pFunction := FindIATEntry(@Windows.GetSysColorBrush);
    if Assigned(pFunction) then
      ReplaceImportFunction(pFunction, @GetSysColorBrushDark);
  end;

  pLibrary:= FindImportLibrary(MainInstance, gdi32);
  if Assigned(pLibrary) then
  begin
    hModule:= GetModuleHandle(gdi32);
    pFunction:= FindImportFunction(pLibrary, Pointer(DeleteObjectOld));
    // UPX purpose
    if pFunction=nil then
      pFunction := FindIATEntry(@Windows.DeleteObject);
    if Assigned(pFunction) then
    begin
      ReplaceImportFunction(pFunction, @__DeleteObject);
    end;
  end
  else
  begin
    // UPX purpose
    pFunction := FindIATEntry(@Windows.DeleteObject);
    if Assigned(pFunction) then
      ReplaceImportFunction(pFunction, @__DeleteObject);
  end;

  hModule:= GetModuleHandle(comctl32);
  pImpDesc:= FindDelayImportLibrary(hModule, themelib);
  if Assigned(pImpDesc) then
  begin
    hUxTheme:= GetModuleHandle(themelib);
    Pointer(TrampolineOpenNCThemeData):= GetProcAddress(hUxTheme, MAKEINTRESOURCEA(49));
    Pointer(TrampolineOpenThemeData):= GetProcAddress(hUxTheme, 'OpenThemeData');
    Pointer(TrampolineDrawThemeText):= GetProcAddress(hUxTheme, 'DrawThemeText');
    Pointer(TrampolineDrawThemeBackground):= GetProcAddress(hUxTheme, 'DrawThemeBackground');

    ReplaceDelayImportFunctionByOrdinal(hModule, pImpDesc, 49, @InterceptOpenNCThemeData);
    ReplaceDelayImportFunction(hModule, pImpDesc, 'OpenThemeData', @InterceptOpenThemeData);
    ReplaceDelayImportFunction(hModule, pImpDesc, 'DrawThemeText', @InterceptDrawThemeText);
    ReplaceDelayImportFunction(hModule, pImpDesc, 'DrawThemeBackground', @InterceptDrawThemeBackground);

    ReplaceDelayImportFunction(hModule, pImpDesc, 'DrawThemeEdge', @DrawThemeEdgeDark);
  end;

  pLibrary:= FindImportLibrary(hModule, gdi32);
  if Assigned(pLibrary) then
  begin
    pFunction:= FindImportFunction(pLibrary, Pointer(DeleteObjectOld));
    if Assigned(pFunction) then
    begin
      ReplaceImportFunction(pFunction, @__DeleteObject);
    end;
  end;

  hModule:= GetModuleHandle(comctl32);
  pLibrary:= FindImportLibrary(hModule, user32);
  if Assigned(pLibrary) then
  begin
    hModule:= GetModuleHandle(user32);

    pFunction:= FindImportFunction(pLibrary, GetProcAddress(hModule, 'DrawEdge'));
    if Assigned(pFunction) then
    begin
      ReplaceImportFunction(pFunction, @_DrawEdge);
    end;
  end;
end;

initialization
  RegisterMetaDarkStyleHandlers(@ApplyWin32MetaDarkStyle, @DarkFormChanged);
finalization
  RegisterMetaDarkStyleHandlers(nil, nil);
  if Assigned(ThemeClass) then
    FreeAndNil(ThemeClass);
  if Assigned(ThemeWindow) then
    FreeAndNil(ThemeWindow);
end.
