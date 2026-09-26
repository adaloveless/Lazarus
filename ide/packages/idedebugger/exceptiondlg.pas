{               ----------------------------------------------
                 exceptiondlg.pas  -  Exception Dialog
                ----------------------------------------------

 ***************************************************************************
 *                                                                         *
 *   This source is free software; you can redistribute it and/or modify   *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This code is distributed in the hope that it will be useful, but      *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   General Public License for more details.                              *
 *                                                                         *
 *   A copy of the GNU General Public License is available on the World    *
 *   Wide Web at <http://www.gnu.org/copyleft/gpl.html>. You can also      *
 *   obtain it by writing to the Free Software Foundation,                 *
 *   Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.   *
 *                                                                         *
 ***************************************************************************
}
unit ExceptionDlg;

{$mode objfpc}{$H+}

interface

uses
  Classes, math, Forms, Controls, Dialogs, StdCtrls, Buttons, Clipbrd, LCLType,
  IDEImagesIntf, IdeIntfStrConsts, IdeDebuggerStringConstants;

type
  
  { TIDEExceptionDlg }

  TIDEExceptionDlg = class(TForm)
    btnBreak: TBitBtn;
    btnContinue: TBitBtn;
    btnCopy: TBitBtn;
    cbIgnoreExceptionType: TCheckBox;
    lblMessage: TLabel;
    procedure btnCopyClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  private
    { private declarations }
  public
    constructor Create(AOwner: TComponent); override;
    function Execute(AMessage: String; out IgnoreException: Boolean): TModalResult;
  end;

function ExecuteExceptionDialog(AMessage: String; out IgnoreException: Boolean;
                                AskIgnore: Boolean = True): TModalResult;

implementation

{$R *.lfm}

function ExecuteExceptionDialog(AMessage: String; out IgnoreException: Boolean;
  AskIgnore: Boolean = True): TModalResult;
var
  ADialog: TIDEExceptionDlg;
begin
  ADialog := TIDEExceptionDlg.Create(Application);
  try
    ADialog.cbIgnoreExceptionType.Visible := AskIgnore;
    Result := ADialog.Execute(AMessage, IgnoreException);
  finally
    ADialog.Free;
  end;
end;

{ TIDEExceptionDlg }

constructor TIDEExceptionDlg.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := lisExceptionDialog;
  btnBreak.Caption := lisMenuBreak;
  btnContinue.Caption := lisBtnContinue;
  btnCopy.Caption := lisCopy;
  cbIgnoreExceptionType.Caption := lisIgnoreExceptionType;

  IDEImages.AssignImage(btnBreak, 'menu_pause');
  IDEImages.AssignImage(btnContinue, 'menu_run');
  IDEImages.AssignImage(btnCopy, 'laz_copy');

  DefaultControl := btnBreak;
  CancelControl := btnContinue;

  RegisterDialogForCopyToClipboard(Self);
end;

procedure TIDEExceptionDlg.btnCopyClick(Sender: TObject);
begin
  // The message exactly as shown (class, text, file and line), without the
  // button captions the generic dialog copy adds. The dialog stays open.
  Clipboard.AsText := lblMessage.Caption;
end;

procedure TIDEExceptionDlg.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // OnKeyDown runs before the handler RegisterDialogForCopyToClipboard adds,
  // so Ctrl+C / Ctrl+Ins copy the same text as the Copy button.
  if (Key in [VK_C, VK_INSERT]) and (Shift = [ssModifier]) then
  begin
    btnCopyClick(nil);
    Key := 0;
  end;
end;

function TIDEExceptionDlg.Execute(AMessage: String; out IgnoreException: Boolean): TModalResult;
begin
  lblMessage.Constraints.MaxWidth := max(1, Screen.DesktopWidth-10);
  lblMessage.Constraints.MaxHeight := max(1, Screen.DesktopHeight-100);
  lblMessage.Caption := AMessage;
  Result := ShowModal;
  IgnoreException := cbIgnoreExceptionType.Checked;
end;

end.

