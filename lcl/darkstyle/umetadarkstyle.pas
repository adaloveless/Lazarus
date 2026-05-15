{
@author(Andrey Zubarev <zamtmn@yandex.ru>)
}

unit uMetaDarkStyle;
{$mode objfpc}{$H+}

interface

{$IFDEF WINDOWS}
uses
    uDarkStyleParams,
    {$IF DEFINED(LCLWIN32) OR DEFINED(LCLQT5) OR DEFINED(LCLQT6)}
    uDarkStyle,
    {$ENDIF}
    {$IFDEF LCLWIN32}
    uWin32WidgetSetDark,
    {$ENDIF}
    uDarkStyleSchemesLoader;
{$ENDIF}

{$IFDEF WINDOWS}
procedure ApplyMetaDarkStyle(const CS:TDSColors);
{$ENDIF}
procedure MetaDarkFormChanged(Form: TObject);

implementation

{$IFDEF WINDOWS}
procedure ApplyMetaDarkStyle(const CS:TDSColors);
begin
  {$IF DEFINED(LCLWIN32) OR DEFINED(LCLQT5) OR DEFINED(LCLQT6)}
  InitDarkMode;
  {$IFDEF LCLWIN32}
  Initialize(CS);
  {$ENDIF}
  ApplyDarkStyle;
  {$ENDIF}
end;
{$ENDIF}

procedure MetaDarkFormChanged(Form: TObject);
begin
  {$IFDEF LCLWIN32}DarkFormChanged(Form);{$ENDIF}
end;
end.
