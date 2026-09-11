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

  Plus SetupStackedBandSeries, which builds the VCLTee "MultiBar = mbStacked"
  status-band breakdown in one call.

  READ THIS BEFORE CHANGING SetupStackedBandSeries. It does NOT create one
  series per band, and the obvious translation that does is WRONG:

    TAChart's Series.Stacked stacks the multiple Y VALUES INSIDE ONE SERIES'
    SOURCE. It does not stack across series, and nothing in it looks at the
    other series on the chart.

  Measured in this tree, not inferred -- TBasicPointSeries.Extent is
  "if FStacked then Source.ExtentCumulative", FindYRange passes FStacked
  straight to Source.FindYRange, and taseries.pas guards the non-stacked
  multi-bar layout with "(not FStacked) and (Source.YCount > 1)". Every one of
  those reads the series' OWN source. So N separate THorizBarSeries each with
  Stacked := True -- which is what the 2026-09-10 version of this function
  built -- all draw from zero and overlap: only the last-drawn band in any
  overlapping range is visible, and the small bands simply never appear. Kara
  (PascalDev_KaraokeDataUtilities) caught that in a rendered chart before I
  caught it in the source; Q&A a_1786485385140_3tz0eu carries her pixel run.

  The correct translation of MultiBar = mbStacked is what is built below: ONE
  series over a TListChartSource with YCount = band count, Stacked := True, a
  TChartStyles carrying the per-band colour and title, and
  Legend.Multiplicity := lmStyle -- without that last one the whole stack
  collapses to a single legend swatch.

  Author: Lars (LazarusDeveloper), 2026-09-10; stacked-band model corrected
  2026-09-11.
}
unit TAChartTeeStyle;

{$MODE ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Graphics, Math,
  TAChartUtils, TADrawUtils, TAGraph, TALegend, TASeries, TASources, TAStyles,
  TAChartTeeChart;

type
  { One stacked band: its legend title and its fill colour. }
  TChartBandSpec = record
    Title: String;
    Color: TColor;
  end;

  TChartBandSpecArray = array of TChartBandSpec;
  TPieRadiusArray = array of Integer;

  { The single stacked-band series and the two objects it needs to stay
    correct. All three are owned by the chart; the record is just a handle so
    a caller does not have to dig them back out of it. BandCount is kept
    because Source.YCount is a Cardinal and mixing it into Integer arithmetic
    at every call site is how off-by-ones get written. }
  TStackedBandChart = record
    Series: THorizBarSeries;
    Source: TListChartSource;
    Styles: TChartStyles;
    BandCount: Integer;
  end;

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

{ Builds the ONE stacked band series described in the unit header -- see there
  for why it is one series and not one per band. Bands stack in array order,
  ABands[0] against the axis. }
function SetupStackedBandSeries(AChart: TChart;
  const ABands: array of TChartBandSpec): TStackedBandChart;

{ Adds one stacked bar at AX. AValues holds the SEGMENT LENGTHS in band order,
  not running totals -- TAChart cumulates them itself. Raises if the count does
  not match the bands, because a short list otherwise plots a truncated stack
  that looks exactly like real data. }
procedure AddStackedBandPoint(const ABandChart: TStackedBandChart;
  AX: Double; const AValues: array of Double);

{ Clears the band data -- the VCLTee "clear the chart data" idiom. The band
  specs, colours and legend styling survive. }
procedure ClearBandSeries(const ABandChart: TStackedBandChart);

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
  const ABands: array of TChartBandSpec): TStackedBandChart;
var
  i: Integer;
  style: TChartStyle;
begin
  Result.BandCount := Length(ABands);

  // One source, YCount = band count. This is what makes Stacked mean anything:
  // see the unit header -- Stacked cumulates the Y values of THIS source.
  Result.Source := TListChartSource.Create(AChart);
  Result.Source.YCount := Result.BandCount;

  // One style per band. The style carries the colour and the legend text; the
  // series' own SeriesColor/BarBrush would colour the WHOLE stack one colour.
  Result.Styles := TChartStyles.Create(AChart);
  for i := 0 to High(ABands) do begin
    style := Result.Styles.Add;
    style.Brush.Color := ABands[i].Color;
    style.Pen.Color := ABands[i].Color;
    style.Text := ABands[i].Title;
  end;

  Result.Series := THorizBarSeries.Create(AChart);
  Result.Series.Source := Result.Source;
  Result.Series.Styles := Result.Styles;
  Result.Series.Stacked := true;
  Result.Series.Marks.Visible := false;
  // Without lmStyle the whole stack shows as ONE legend entry, which is the
  // single most visible way this differs from the VCLTee original.
  Result.Series.Legend.Multiplicity := lmStyle;
  AChart.AddSeries(Result.Series);
end;

procedure AddStackedBandPoint(const ABandChart: TStackedBandChart;
  AX: Double; const AValues: array of Double);
begin
  if Length(AValues) <> ABandChart.BandCount then
    raise EChartError.CreateFmt(
      'AddStackedBandPoint: %d value(s) for %d band(s)',
      [Length(AValues), ABandChart.BandCount]);
  ABandChart.Source.AddXYList(AX, AValues);
end;

procedure ClearBandSeries(const ABandChart: TStackedBandChart);
begin
  // Clear the SOURCE, not the series: the series does not own it, and
  // TChartSeries.Clear on a series with an external source is a no-op on the
  // data while leaving the caller believing the chart was emptied.
  ABandChart.Source.Clear;
end;

end.
