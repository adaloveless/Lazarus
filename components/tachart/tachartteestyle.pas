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
  TARadialSeries, TAChartTeeChart;

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
  AX: Double; const AValues: array of Double); overload;

{ Same, plus the bar's category label (a book name, a month...). The category
  axis reads its marks from the band source (see SetupStackedBandSeries), so
  this label is what the axis shows beside the bar -- without it the axis only
  shows AX. }
procedure AddStackedBandPoint(const ABandChart: TStackedBandChart;
  AX: Double; const AValues: array of Double; const ALabel: String); overload;

{ Makes a chart read as a pie chart instead of a pie inside an XY plot. A
  TChart draws its axes whether or not any series uses them, so a pie gets an
  empty value scale and a 0..1 category scale around it: SetupPieChart hides
  every axis. It also gives the legend one row per slice (lmPoint: the default
  lmSingle shows only the series title, so no colour can be matched to a
  meaning) and marks every slice "Label  12%", with the count in the legend. }
procedure SetupPieChart(AChart: TChart; ASeries: TCustomPieSeries);

{ Replaces the slices, largest first. A long tail otherwise turns into hundreds
  of unlabelled slivers that carry no information, so two rules fold items into
  one grey "Other (n)" slice: with AMaxSlices > 0, everything past the
  AMaxSlices-1 largest; and every item under AMinShare of the total (default 2%,
  where a slice is too thin to label). AColors gives one colour per INPUT item
  (it follows the item through the sort); pass an empty array for
  PIE_PALETTE, which has no grey so "Other" is never confused with a slice.
  ALabels is UnicodeString because the callers are delphiunicode forms and an
  open array does not convert implicitly; TAChart stores the labels UTF-8. }
procedure SetPieSlices(ASeries: TCustomPieSeries; const ALabels: array of UnicodeString;
  const AValues: array of Double; const AColors: array of TColor;
  AMaxSlices: Integer = 0; AMinShare: Double = 0.02);

const
  { Qualitative palette for pie slices (Tableau 10 minus its grey), as TColor
    ($00BBGGRR). Distinct hues, none of them red-first, so the largest slice
    does not read as an error. }
  PIE_PALETTE: array[0..8] of TColor = (
    $B4771F, $0E7FFF, $2CA02C, $2827D6, $BD6794, $4B568C, $C277E3, $22BDBC,
    $CFBE17);
  PIE_OTHER_COLOR = $7F7F7F;

{ Clears the band data -- the VCLTee "clear the chart data" idiom. The band
  specs, colours and legend styling survive. }
procedure ClearBandSeries(const ABandChart: TStackedBandChart);

{ Attaches a three-ring frame to AChart via OnAfterDraw and returns the framer
  (owned by the chart) so ring colours and width can be retuned. }
function AttachThreeRingFrame(AChart: TChart): TThreeRingPieFramer;

implementation

uses
  TAChartAxis, TAChartAxisUtils, TATextElements;

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
  cat, val: TChartAxis;
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

  // The category axis (the series' X axis -- the LEFT one for a horizontal
  // bar) takes its marks from the band source: one mark per bar, showing the
  // label given to AddStackedBandPoint. Otherwise the axis generates numeric
  // ticks (0, 2, 4...) that name nothing.
  cat := AChart.AxisList.GetAxisByAlign(calLeft);
  if (Result.Series.AxisIndexX >= 0) and (Result.Series.AxisIndexX < AChart.AxisList.Count) then
    cat := AChart.AxisList[Result.Series.AxisIndexX];
  if cat <> nil then begin
    cat.Marks.Source := Result.Source;
    cat.Marks.Style := smsLabel;
    cat.Marks.AtDataOnly := true;
    // A vertical axis positions source marks by their Y value (TChartAxis
    // FUseY = IsVertical xor SourceExchangeXY). For a horizontal bar the
    // category is X and Y is the first band's value, so without this each
    // label lands at that value -- all but the ones whose first band happens
    // to fall inside the category range vanish, and those carry the wrong name.
    cat.Marks.SourceExchangeXY := cat.IsVertical;
    cat.Grid.Visible := false;
  end;
  // The value axis: thousands separators, and neighbouring marks that would
  // overlap are hidden instead of being printed on top of each other.
  val := AChart.AxisList.GetAxisByAlign(calBottom);
  if (Result.Series.AxisIndexY >= 0) and (Result.Series.AxisIndexY < AChart.AxisList.Count) then
    val := AChart.AxisList[Result.Series.AxisIndexY];
  if val <> nil then begin
    val.Marks.Format := '%0:.0n';
    val.Marks.OverlapPolicy := opHideNeighbour;
    // "1,000,000" is ~60 px; the 10 px default minimum step prints them edge
    // to edge. Ask for steps at least one label wide.
    val.Intervals.MinLength := 80;
    val.Intervals.MaxLength := 160;
  end;
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

procedure AddStackedBandPoint(const ABandChart: TStackedBandChart;
  AX: Double; const AValues: array of Double; const ALabel: String);
begin
  if Length(AValues) <> ABandChart.BandCount then
    raise EChartError.CreateFmt(
      'AddStackedBandPoint: %d value(s) for %d band(s)',
      [Length(AValues), ABandChart.BandCount]);
  ABandChart.Source.AddXYList(AX, AValues, ALabel);
end;

procedure SetupPieChart(AChart: TChart; ASeries: TCustomPieSeries);
var
  i: Integer;
begin
  for i := 0 to AChart.AxisList.Count - 1 do
    AChart.AxisList[i].Visible := false;
  AChart.Frame.Visible := false;

  // One legend row per slice: "Verified  28,700". Format args are the mark
  // args -- 0 value, 1 percent, 2 label, 3 total.
  ASeries.Legend.Multiplicity := lmPoint;
  ASeries.Legend.Format := '%2:s  %0:.0n';
  // Under the pie, not beside it: a legend on the right takes the width of a
  // narrow chart and the pie shrinks to fit what is left.
  AChart.Legend.Alignment := laBottomCenter;

  // On the pie: label and share. The count lives in the legend, so the marks
  // stay short enough to sit beside small slices.
  ASeries.Marks.Visible := true;
  ASeries.Marks.Style := smsCustom;           // before Format: Style overwrites it
  ASeries.Marks.Format := '%2:s  %1:.0f%%';
  ASeries.Marks.OverlapPolicy := opHideNeighbour;
  ASeries.Marks.LabelFont.Color := clWhite;
  ASeries.Marks.LabelBrush.Color := clBlack;
  ASeries.Marks.LinkPen.Color := clSilver;
  ASeries.Marks.Frame.Color := clGray;
  ASeries.MarkPositions := pmpAround;
end;

procedure SetPieSlices(ASeries: TCustomPieSeries; const ALabels: array of UnicodeString;
  const AValues: array of Double; const AColors: array of TColor;
  AMaxSlices: Integer; AMinShare: Double);
var
  order: array of Integer;
  i, j, t, n, keep: Integer;
  total, other: Double;
  c: TColor;
begin
  n := Min(Length(ALabels), Length(AValues));
  SetLength(order, n);
  total := 0;
  for i := 0 to n - 1 do begin
    order[i] := i;
    total := total + AValues[i];
  end;
  // Largest first. Insertion sort: slice counts are small, and genre-sized
  // inputs (hundreds) are still trivial.
  for i := 1 to n - 1 do begin
    t := order[i];
    j := i - 1;
    while (j >= 0) and (AValues[order[j]] < AValues[t]) do begin
      order[j + 1] := order[j];
      Dec(j);
    end;
    order[j + 1] := t;
  end;

  keep := n;
  if (AMaxSlices > 0) and (n > AMaxSlices) then
    keep := AMaxSlices - 1;       // the last slot is "Other"
  // sorted descending, so the first slice under the share ends the kept run
  while (keep > 0) and (total > 0) and (AValues[order[keep - 1]] < AMinShare * total) do
    Dec(keep);
  // folding ONE item into "Other" only renames it: keep it as itself
  if keep = n - 1 then
    keep := n;

  ASeries.BeginUpdate;
  try
    ASeries.Clear;
    for i := 0 to keep - 1 do begin
      if order[i] < Length(AColors) then
        c := AColors[order[i]]
      else
        c := PIE_PALETTE[i mod Length(PIE_PALETTE)];
      ASeries.Add(AValues[order[i]], UTF8Encode(ALabels[order[i]]), c);
    end;
    if keep < n then begin
      other := 0;
      for i := keep to n - 1 do
        other := other + AValues[order[i]];
      ASeries.Add(other, Format('Other (%d)', [n - keep]), PIE_OTHER_COLOR);
    end;
  finally
    ASeries.EndUpdate;
  end;
end;

procedure ClearBandSeries(const ABandChart: TStackedBandChart);
begin
  // Clear the SOURCE, not the series: the series does not own it, and
  // TChartSeries.Clear on a series with an external source is a no-op on the
  // data while leaving the caller believing the chart was emptied.
  ABandChart.Source.Clear;
end;

end.
