package crack

import scala.scalajs.js
import scala.scalajs.js.Dynamic.literal as obj

/**
 * ECharts-options. Färgerna är elmix palett — samma hus, samma ton.
 *
 * Ingen av funktionerna här rör DOM eller state; de tar avkodad data och
 * returnerar en option. Det gör dem läsbara var för sig och byggbara om utan
 * att något ritas.
 */
object Charts:

  // -- palett (elmix) -------------------------------------------------------
  val Ink    = "#222"
  val Muted  = "#666"
  val Faint  = "#888"
  val Grid   = "#e3e8ef"
  val Ref    = "#36c"
  val Focus  = "#2e6fd6" // Sverige
  val Other  = "#c9d2e0" // övriga EU
  val Usa    = "#c0392b"
  val Above  = "#1a9850" // över tröskel  (RdYlGn-ändpunkt)
  val Below  = "#d73027" // under tröskel
  val Spread = Vector("#2e6fd6", "#9c6b3f", "#4dc4d4")

  /** Publicerade US-retailpriser är USD/L; dubbelaxeldiagrammet visar USD/gal. */
  private val LitresPerGallon = 3.785411784

  // -- småverktyg -----------------------------------------------------------

  private def fixed(v: Double, dp: Int): String =
    v.asInstanceOf[js.Dynamic].toFixed(dp).asInstanceOf[String]

  /** None -> JS null, vilket ECharts ritar som avbrott. Aldrig 0. */
  private def data(s: Data.Series): js.Array[js.Any] =
    val a = js.Array[js.Any]()
    s.foreach(o => a.push(o.map(v => v: js.Any).orNull))
    a

  private def axisX(weeks: Vector[String]): js.Object = obj(
    `type` = "category",
    data = js.Array(weeks*),
    boundaryGap = false,
    axisLine = obj(lineStyle = obj(color = Grid)),
    axisLabel = obj(color = Muted, fontSize = 11)
  )

  private def axisY(name: String): js.Object = obj(
    `type` = "value",
    name = name,
    nameTextStyle = obj(color = Muted, fontSize = 11, align = "left"),
    scale = true,
    axisLine = obj(show = false),
    axisTick = obj(show = false),
    axisLabel = obj(color = Muted, fontSize = 11),
    splitLine = obj(lineStyle = obj(color = Grid))
  )

  /** Panorering med hjul/drag plus en diskret reglagelist — 240 veckor är tätt. */
  private def zoom: js.Array[js.Object] = js.Array(
    obj(`type` = "inside"),
    obj(`type` = "slider", height = 16, bottom = 8, borderColor = Grid,
        fillerColor = "rgba(54,102,204,0.10)", handleStyle = obj(color = Ref),
        textStyle = obj(color = Faint, fontSize = 10))
  )

  private def gridBox: js.Object =
    obj(left = 58, right = 62, top = 30, bottom = 58, containLabel = false)

  // -- crack: linjeläge -----------------------------------------------------

  def crackLine(d: Data.Cracks, region: String): js.Any =
    val ss = d.spreads(region)
    obj(
      grid = gridBox,
      legend = obj(top = 0, icon = "roundRect", itemWidth = 14, itemHeight = 3,
                   textStyle = obj(color = Muted, fontSize = 12)),
      tooltip = obj(
        trigger = "axis",
        axisPointer = obj(`type` = "line", lineStyle = obj(color = Grid)),
        formatter = ((ps: js.Array[js.Dynamic]) =>
          val head = ps.headOption.map(p => s"<b>${p.axisValue}</b>").getOrElse("")
          val rows = ps.toVector.map { p =>
            val v = p.value
            val txt = if v == null || js.isUndefined(v) then "–"
                      else s"${fixed(v.asInstanceOf[Double], 2)} USD/bbl"
            s"${p.marker}${p.seriesName}: $txt"
          }
          (head +: rows).mkString("<br>")
        ): js.Function1[js.Array[js.Dynamic], String]
      ),
      xAxis = axisX(d.weeks),
      yAxis = axisY("USD/bbl"),
      dataZoom = zoom,
      series = js.Array(
        ss.zipWithIndex.map { (s, i) =>
          obj(
            name = s.label, `type` = "line",
            showSymbol = false, connectNulls = false,
            lineStyle = obj(width = 1.8, color = Spread(i % Spread.length)),
            itemStyle = obj(color = Spread(i % Spread.length)),
            emphasis = obj(focus = "series"),
            data = data(s.values)
          ): js.Object
        }*
      )
    )

  // -- crack: tröskelläge ("mountain") -------------------------------------

  /**
   * Ytan mellan serien och tröskeln fylls grön över, röd under. visualMap på
   * y-dimensionen färgar både linjen och areaStyle, så gränsen hamnar exakt vid
   * tröskeln utan att serien behöver delas i två.
   *
   * En serie i taget: med två fyllda serier lägger sig ytorna över varandra och
   * poängen — var marginalen ligger mot tröskeln — går förlorad.
   */
  def crackThreshold(d: Data.Cracks, s: Data.Crack, threshold: Double): js.Any =
    obj(
      grid = gridBox,
      tooltip = obj(
        trigger = "axis",
        axisPointer = obj(`type` = "line", lineStyle = obj(color = Grid)),
        formatter = ((ps: js.Array[js.Dynamic]) =>
          ps.headOption.fold("") { p =>
            val v = p.value
            if v == null || js.isUndefined(v) then s"<b>${p.axisValue}</b><br>no observation"
            else
              val d0 = v.asInstanceOf[Double]
              val rel = if d0 >= threshold then "above" else "below"
              s"<b>${p.axisValue}</b><br>${s.label}: ${fixed(d0, 2)} USD/bbl" +
                s"<br><span style='color:${if d0 >= threshold then Above else Below}'>" +
                s"${fixed(math.abs(d0 - threshold), 2)} $rel threshold</span>"
          }
        ): js.Function1[js.Array[js.Dynamic], String]
      ),
      xAxis = axisX(d.weeks),
      yAxis = axisY("USD/bbl"),
      dataZoom = zoom,
      visualMap = obj(
        show = false, `type` = "piecewise", seriesIndex = 0, dimension = 1,
        // Bitarna MÅSTE vara begränsade i båda ändar. Med öppna gränser
        // ({lt: t}, {gte: t}) kan ECharts getVisualGradient inte placera
        // färgstoppen längs axeln, och hela diagrammet kastar
        // "Cannot read properties of undefined (reading 'coord')".
        // Gränserna är godtyckligt vida — de ligger långt utanför varje
        // crack-spread som verify.sql släpper igenom.
        pieces = js.Array(
          obj(min = -1.0e6, max = threshold, color = Below): js.Object,
          obj(min = threshold, max = 1.0e6, color = Above): js.Object
        )
      ),
      series = js.Array(
        obj(
          name = s.label, `type` = "line",
          showSymbol = false,
          // Fyllningen bryts vid saknad vecka i stället för att spänna över den.
          connectNulls = false,
          lineStyle = obj(width = 1.4),
          areaStyle = obj(origin = threshold, opacity = 0.32),
          markLine = obj(
            silent = true, symbol = "none",
            lineStyle = obj(`type` = "dashed", color = Ref, width = 1),
            label = obj(formatter = s"threshold ${fixed(threshold, 0)}",
                        position = "insideEndTop", color = Ref, fontSize = 11),
            data = js.Array(obj(yAxis = threshold): js.Object)
          ),
          data = data(s.values)
        ): js.Object
      )
    )

  // -- retail ---------------------------------------------------------------

  /**
   * Sverige framhävt, övriga EU tunt grått, USA streckat. Ritordningen sätter
   * z: de grå ligger underst så att Sverige aldrig hamnar bakom dem.
   *
   * emphasis.focus + blur ger hover-effekten: den linje pekaren är vid lyfts
   * fram och resten bleknar, vilket är det enda sättet att läsa ut ett enskilt
   * land ur ett knippe på 28.
   */
  def retail(
      r: Data.Retails, fx: Data.Fx,
      fuel: String, tax: String, ccy: String
  ): js.Any =
    val picked  = r.pick(fuel, tax)
    val grey    = picked.filter(s => !s.focus && s.region != "US")
    val ordered = grey ++ picked.filter(_.region == "US") ++ picked.filter(_.focus)
    val unit    = s"$ccy/L"

    def colorOf(s: Data.Retail) =
      if s.focus then Focus else if s.region == "US" then Usa else Other

    obj(
      grid = gridBox,
      tooltip = obj(
        trigger = "item",
        formatter = ((p: js.Dynamic) =>
          val v = p.value
          if v == null || js.isUndefined(v) then s"${p.seriesName}<br>${p.name}: –"
          else s"<b>${p.seriesName}</b><br>${p.name}: ${fixed(v.asInstanceOf[Double], 3)} $unit"
        ): js.Function1[js.Dynamic, String]
      ),
      xAxis = axisX(r.weeks),
      yAxis = axisY(unit),
      dataZoom = zoom,
      series = js.Array(
        ordered.map { s =>
          val vals = s.values.zipWithIndex.map { (o, i) =>
            o.map(v => fx.convert(v, s.currency, ccy, i))
          }
          obj(
            name = s.label, `type` = "line",
            showSymbol = false, connectNulls = false,
            z = if s.focus then 10 else if s.region == "US" then 8 else 2,
            lineStyle = obj(
              width = if s.focus then 2.6 else if s.region == "US" then 1.8 else 0.9,
              color = colorOf(s),
              `type` = if s.region == "US" then "dashed" else "solid"
            ),
            itemStyle = obj(color = colorOf(s)),
            emphasis = obj(focus = "series", lineStyle = obj(width = 2.6)),
            blur = obj(lineStyle = obj(opacity = 0.12)),
            // Bara de två serier som ska gå att hitta utan legend får ändetikett.
            endLabel = obj(show = s.focus || s.region == "US", formatter = s.cc,
                           color = colorOf(s), fontSize = 11, distance = 4),
            data = data(vals)
          ): js.Object
        }*
      )
    )

  // -- dubbelaxel: "rockets and feathers" ----------------------------------

  /**
   * Råolja (USD/fat, vänster) mot amerikanskt pumppris (USD/gallon, höger).
   * Två axlar därför att enheterna är olika storleksordningar — att tvinga in
   * dem på en axel gör pumpkurvan platt och asymmetrin osynlig.
   */
  def rocketsFeathers(c: Data.Cracks, r: Data.Retails): js.Any =
    val crude = Vector("brent" -> "#c0392b", "wti" -> "#9c6b3f").flatMap { (k, col) =>
      c.level(k).map(s => (s.label, s.values, col))
    }
    val pump = r.pick("diesel", "with").filter(_.region == "US").map(s =>
      (s"US retail diesel", s.values.map(_.map(_ * LitresPerGallon)), "#2e6fd6")
    ) ++ r.pick("gasoline", "with").filter(_.region == "US").map(s =>
      (s"US retail gasoline", s.values.map(_.map(_ * LitresPerGallon)), "#4dc4d4")
    )

    val units: Map[String, String] =
      (crude.map(_._1 -> "USD/bbl") ++ pump.map(_._1 -> "USD/gal")).toMap

    def line(name: String, v: Data.Series, col: String, axis: Int) = obj(
      name = name, `type` = "line", yAxisIndex = axis,
      showSymbol = false, connectNulls = false,
      lineStyle = obj(width = if axis == 0 then 1.6 else 2.2, color = col),
      itemStyle = obj(color = col),
      emphasis = obj(focus = "series"),
      data = data(v)
    ): js.Object

    obj(
      grid = gridBox,
      legend = obj(top = 0, icon = "roundRect", itemWidth = 14, itemHeight = 3,
                   textStyle = obj(color = Muted, fontSize = 12)),
      tooltip = obj(
        trigger = "axis",
        axisPointer = obj(`type` = "line", lineStyle = obj(color = Grid)),
        // Per serie-enhet, inte en delad: vänster axel är fat, höger gallon.
        formatter = ((ps: js.Array[js.Dynamic]) =>
          val head = ps.headOption.map(p => s"<b>${p.axisValue}</b>").getOrElse("")
          val rows = ps.toVector.map { p =>
            val n = p.seriesName.asInstanceOf[String]
            val v = p.value
            val txt = if v == null || js.isUndefined(v) then "–"
                      else s"${fixed(v.asInstanceOf[Double], 2)} ${units.getOrElse(n, "")}"
            s"${p.marker}$n: $txt"
          }
          (head +: rows).mkString("<br>")
        ): js.Function1[js.Array[js.Dynamic], String]
      ),
      xAxis = axisX(c.weeks),
      yAxis = js.Array(axisY("USD/bbl"), axisY("USD/gal")),
      dataZoom = zoom,
      series = js.Array(
        (crude.map((n, v, col) => line(n, v, col, 0)) ++
          pump.map((n, v, col) => line(n, v, col, 1)))*
      )
    )
