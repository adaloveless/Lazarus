{
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
      drawer alike.

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
  TChartBandSeriesArray = array of THorizBarSeries;

  { Draws three concentric hollow rings over a chart's plot area, at 1/3, 2/3
    and 3/3 of the largest circle that fits. This is DECORATION only -- the
    rings are not driven by series data. Owned by the chart it frames. }
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

constructor TThreeRingPieFramer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FInnerColor := clRed;
  FMiddleColor := clYellow;
  FOuterColor := clGreen;
  FRingWidth := 3;
end;

procedure TThreeRingPieFramer.AfterDraw(ASender: TChart; ADrawer: IChartDrawer);
var
  pr: TRect;
  cx, cy, radius: Integer;

  procedure Ring(ANum: Integer; AColor: TColor);
  var
    rr: Integer;
  begin
    rr := (radius * ANum) div 3;
    if rr <= 0 then exit;
    ADrawer.SetBrushParams(bsClear, clBlack);
    ADrawer.SetPenParams(psSolid, AColor, FRingWidth);
    ADrawer.Ellipse(cx - rr, cy - rr, cx + rr, cy + rr);
  end;

begin
  pr := ASender.ClipRect;
  cx := (pr.Left + pr.Right) div 2;
  cy := (pr.Top + pr.Bottom) div 2;
  radius := Min(pr.Right - pr.Left, pr.Bottom - pr.Top) div 2;
  if radius <= 0 then exit;
  Ring(3, FOuterColor);
  Ring(2, FMiddleColor);
  Ring(1, FInnerColor);
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
