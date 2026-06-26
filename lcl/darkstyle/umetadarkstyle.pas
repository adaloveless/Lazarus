{
@author(Andrey Zubarev <zamtmn@yandex.ru>)
}

unit uMetaDarkStyle;
{$mode objfpc}{$H+}

interface

{$IFDEF WINDOWS}
uses
    uDarkStyleParams,
    uDarkStyle,
    uDarkStyleSchemesLoader;

type
  TApplyMetaDarkStyleHandler = procedure(const CS: TDSColors);
  TMetaDarkFormChangedHandler = procedure(Form: TObject);
{$ENDIF}

{$IFDEF WINDOWS}
procedure ApplyMetaDarkStyle(const CS:TDSColors);
procedure RegisterMetaDarkStyleHandlers(AApply: TApplyMetaDarkStyleHandler;
  AFormChanged: TMetaDarkFormChangedHandler);
{$ENDIF}
procedure MetaDarkFormChanged(Form: TObject);

implementation

{$IFDEF WINDOWS}
var
  ApplyMetaDarkStyleHandler: TApplyMetaDarkStyleHandler = nil;
  MetaDarkFormChangedHandler: TMetaDarkFormChangedHandler = nil;

procedure RegisterMetaDarkStyleHandlers(AApply: TApplyMetaDarkStyleHandler;
  AFormChanged: TMetaDarkFormChangedHandler);
begin
  ApplyMetaDarkStyleHandler := AApply;
  MetaDarkFormChangedHandler := AFormChanged;
end;
{$ENDIF}

{$IFDEF WINDOWS}
procedure ApplyMetaDarkStyle(const CS:TDSColors);
begin
  InitDarkMode;
  if Assigned(ApplyMetaDarkStyleHandler) then
    ApplyMetaDarkStyleHandler(CS)
  {$IF DEFINED(LCLQT5) OR DEFINED(LCLQT6)}
  else
    ApplyDarkStyle
  {$ENDIF}
  ;
end;
{$ENDIF}

procedure MetaDarkFormChanged(Form: TObject);
begin
  {$IFDEF WINDOWS}
  if Assigned(MetaDarkFormChangedHandler) then
    MetaDarkFormChangedHandler(Form);
  {$ENDIF}
end;
end.
