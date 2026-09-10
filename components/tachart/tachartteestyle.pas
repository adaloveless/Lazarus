{ ♦
 *****************************************************************************
  See the file COPYING.modifiedLGPL.txt, included in this distribution,
  for details about the license.
 *****************************************************************************

  TeeChart-parity styling helpers for TAChart.

  TAChartTeeChart supplies the TeeChart-compatible CLASSES (THorizBarSeries,
  TPointSeries, the Style/margin/Logarithmic properties). This unit supplies the
  two TeeChart presentation idioms that have no TAChart equivalent and that a
  ported VCLTee form otherwise has to re-implement by hand:

    * a dark chart theme (black control + plot background, white bold title,
      dark legend, coloured value axis) matching a typical VCLTee dark .dfm;
    * a three-ring concentric FRAME drawn around a pie chart -- TAChart has
      TPieSeries.InnerRadiusPercent (a single donut hole) but no concentric
      ring decoration, so this overlays three hollow ellipse outlines through
      TChart.OnAfterDraw, which fires for the screen canvas and for any export
      drawer alike. The rings are sized from the radii the pie series ACTUALLY
      drew at, not from the plot rectangle -- see TThreeRingPieFramer.AfterDraw
      for why sizing from ClipRect does not frame the pie.

  Plus SetupStackedBandSeries, which builds the N same-axis stacked
  THorizBarSeries that a VCLTee "MultiBar = mbStacked" chart uses for a
  status-band breakdown, in one call.

  Author: Lars (LazarusDeveloper), 2026-09-10.
}
unit TAChartTeeStyle;

{$MODE ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math,
  TAGraph, TASeries, TADrawUtils, TAChartTeeChart;

type
  { One stacked band: its legend title and its fill colour. }
  TChartBandSpec = record
    Title: String;
    Color: TColor;
  end;

  TChartBandSpecArray = array of TChartBandSpec;
  TPieRadiusArray = array of Integer;
  TChartBandSeriesArray = array of THorizBarSeries;

  { Draws three concentric hollow rings centred on a chart's plot area.

    On a chart carrying THREE OR MORE pie series -- a multi-level donut built
    from TPieSeries.FixedRadius + InnerRadiusPercent -- each ring traces one of
    the three outermost series, so the frame outlines real data boundaries.
    On a chart with one or two pie series the rings fall at 1/3, 2/3 and 3/3 of
    the largest pie's radius, so the outer ring still lands on its rim. Only
    when there is no pie series at all does it fall back to the plot rectangle.

    The ring OUTLINES themselves carry no value -- they are decoration; what
    changed is that they now align with the chart instead of floating over it.
    Owned by the chart it frames. }
  TThreeRingPieFramer = class(TComponent)
  private
    FInnerColor: TColor;
    FMiddleColor: TColor;
    FOuterColor: TColor;
    FRingWidth: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    procedure AfterDraw(ASender: TChart; ADrawer: IChartDrawer);
    property InnerColor: TColor read FInnerColor write FInnerColor;
    property MiddleColor: TColor read FMiddleColor write FMiddleColor;
    property OuterColor: TColor read FOuterColor write FOuterColor;
    property RingWidth: Integer read FRingWidth write FRingWidth;
  end;

const
  { VCLTee dark .dfm forms commonly carry Title.Font.Height = -51. }
  DEF_DARK_TITLE_HEIGHT = -51;

{ Black control and plot background, white bold title, dark legend, white axis
  mark labels, AAxisColor value-axis pen. Leaves series colours alone. }
procedure ApplyDarkChartTheme(AChart: TChart;
  AAxisColor: TColor = clAqua; ATitleHeight: Integer = DEF_DARK_TITLE_HEIGHT);

{ Creates one stacked THorizBarSeries per band, in band order, and returns the
  typed references: TChart.Series[N] is a TBasicChartSeries and has no AddXY,
  so a caller that populates by index needs these (or a hard cast). }
function SetupStackedBandSeries(AChart: TChart;
  const ABands: array of TChartBandSpec): TChartBandSeriesArray;

{ Clears every band series -- the VCLTee "clear the chart data" idiom. }
procedure ClearBandSeries(const ASeries: TChartBandSeriesArray);

{ Attaches a three-ring frame to AChart via OnAfterDraw and returns the framer
  (owned by the chart) so ring colours and width can be retuned. }
function AttachThreeRingFrame(AChart: TChart): TThreeRingPieFramer;

implementation

uses
  TARadialSeries;

type
  { TCustomPieSeries.Radius is protected. A descendant declared here may read
    it; this type is never instantiated, it exists only for that access. }
  TPieRadiusAccess = class(TCustomPieSeries);

constructor TThreeRingPieFramer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FInnerColor := clRed;
  FMiddleColor := clYellow;
  FOuterColor := clGreen;
  FRingWidth := 3;
end;

{ Every pie radius drawn on AChart, ascending. TCustomPieSeries computes
  FRadius during its own Draw, and OnAfterDraw fires after all series have
  drawn, so the values are current by the time the framer runs. }
function CollectPieRadii(AChart: TChart): TPieRadiusArray;
var
  i, j, t: Integer;
  s: TBasicChartSeries;
begin
  Result := nil;
  for i := 0 to AChart.SeriesCount - 1 do begin
    s := AChart.Series[i];
    if not (s is TCustomPieSeries) then continue;
    t := TPieRadiusAccess(s).Radius;
    if t <= 0 then continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := t;
  end;
  { Insertion sort: N is the number of pie series on one chart, i.e. tiny. }
  for i := 1 to High(Result) do begin
    t := Result[i];
    j := i - 1;
    while (j >= 0) and (Result[j] > t) do begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := t;
  end;
end;

procedure TThreeRingPieFramer.AfterDraw(ASender: TChart; ADrawer: IChartDrawer);
var
  pr: TRect;
  cx, cy, radius: Integer;
  radii: TPieRadiusArray;

  procedure Ring(ARadius: Integer; AColor: TColor);
  begin
    if ARadius <= 0 then exit;
    ADrawer.SetBrushParams(bsClear, clBlack);
    ADrawer.SetPenParams(psSolid, AColor, FRingWidth);
    ADrawer.Ellipse(cx - ARadius, cy - ARadius, cx + ARadius, cy + ARadius);
  end;

begin
  pr := ASender.ClipRect;
  cx := (pr.Left + pr.Right) div 2;
  cy := (pr.Top + pr.Bottom) div 2;

  { Size the rings from the pie, not from the plot rectangle. TCustomPieSeries
    shrinks its radius until its MARKS fit inside ClipRect, and FixedRadius
    ignores ClipRect entirely, so a ClipRect-sized frame does not frame the
    pie: the outer ring floats outside it and the middle ring cuts across the
    slices at no meaningful radius. The centres never needed fixing -- a pie
    already centres on CenterPoint(ClipRect), which is what cx,cy are. }
  radii := CollectPieRadii(ASender);

  if Length(radii) >= 3 then begin
    { A real multi-level donut: outline its three outermost rings. }
    Ring(radii[High(radii)], FOuterColor);
    Ring(radii[High(radii) - 1], FMiddleColor);
    Ring(radii[High(radii) - 2], FInnerColor);
    exit;
  end;

  if Length(radii) > 0 then
    radius := radii[High(radii)]
  else
    { No pie on this chart: the largest circle that fits, as before. }
    radius := Min(pr.Right - pr.Left, pr.Bottom - pr.Top) div 2;
  if radius <= 0 then exit;
  Ring(radius, FOuterColor);
  Ring((radius * 2) div 3, FMiddleColor);
  Ring(radius div 3, FInnerColor);
end;

function AttachThreeRingFrame(AChart: TChart): TThreeRingPieFramer;
begin
  Result := TThreeRingPieFramer.Create(AChart);
  AChart.OnAfterDraw := @Result.AfterDraw;
end;

procedure ApplyDarkChartTheme(AChart: TChart;
  AAxisColor: TColor = clAqua; ATitleHeight: Integer = DEF_DARK_TITLE_HEIGHT);
begin
  AChart.Color := clBlack;
  AChart.BackColor := clBlack;

  AChart.Title.Visible := true;
  AChart.Title.Font.Color := clWhite;
  AChart.Title.Font.Style := [fsBold];
  AChart.Title.Font.Height := ATitleHeight;

  AChart.Foot.Font.Color := clWhite;

  { Without this the legend keeps the widgetset default panel colours and reads
    as a light rectangle sitting on a black chart. }
  AChart.Legend.Font.Color := clWhite;
  AChart.Legend.BackgroundBrush.Color := clBlack;
  AChart.Legend.Frame.Color := AAxisColor;

  AChart.LeftAxis.AxisPen.Visible := true;
  AChart.LeftAxis.AxisPen.Color := AAxisColor;
  AChart.LeftAxis.Marks.LabelFont.Color := clWhite;
  AChart.LeftAxis.Title.LabelFont.Color := clWhite;

  AChart.BottomAxis.AxisPen.Visible := true;
  AChart.BottomAxis.AxisPen.Color := AAxisColor;
  AChart.BottomAxis.Marks.LabelFont.Color := clWhite;
  AChart.BottomAxis.Title.LabelFont.Color := clWhite;
end;

function SetupStackedBandSeries(AChart: TChart;
  const ABands: array of TChartBandSpec): TChartBandSeriesArray;
var
  i: Integer;
  s: THorizBarSeries;
begin
  // Result := nil first: SetLength takes Result as a var parameter, and the
  // compiler's flow analysis counts that as a READ of an as-yet unassigned
  // managed-type result (warning 5093). The IDE build compiles this package
  // with -vewnhibq, so an unfixed 5093 would print in every user's IDE
  // rebuild once this unit joins the package.
  Result := nil;
  SetLength(Result, Length(ABands));
  for i := 0 to High(ABands) do begin
    s := THorizBarSeries.Create(AChart);
    s.Title := ABands[i].Title;
    s.SeriesColor := ABands[i].Color;
    s.BarBrush.Color := ABands[i].Color;
    s.BarPen.Color := ABands[i].Color;
    s.Stacked := true;
    s.Marks.Visible := false;
    AChart.AddSeries(s);
    Result[i] := s;
  end;
end;

procedure ClearBandSeries(const ASeries: TChartBandSeriesArray);
var
  i: Integer;
begin
  for i := 0 to High(ASeries) do
    ASeries[i].Clear;
end;

end.
