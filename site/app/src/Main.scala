package crack

import com.raquo.laminar.api.L.*
import org.scalajs.dom
import scala.scalajs.js
import scala.util.{Success, Failure}

/**
 * Laminar-appen: hämtar de tre JSON-filerna, håller reglagens tillstånd och
 * matar ECharts. All omräkning sker här i webbläsaren mot redan hämtad data —
 * inget reglage utlöser ett nätanrop.
 */
object Main:

  private val DataBase = "public/data"

  // -- reglage --------------------------------------------------------------
  private val crackRegion = Var("US")
  private val crackMode   = Var("threshold")   // "line" | "threshold"
  private val crackPick   = Var("us_ulsd_brent")
  private val threshold   = Var(25.0)
  private val crackScale  = Var("weekly")     // "weekly" | "daily"
  private val crackRuler  = Var(true)         // 7-dagarslinjalen i dagsläget

  private val retailFuel  = Var("diesel")      // "diesel" | "gasoline"
  private val retailTax    = Var("with")       // "with" | "without"
  private val retailCcy    = Var("EUR")        // "EUR" | "USD" | "SEK"

  private val usFuel = Var("gasoline")         // egen växel: sektionen står för sig
  private val usCcy  = Var("USD")              // regional jämförelse läses bäst i USD

  /** Smal skärm -> färre ändetiketter. Uppdateras vid rotation och storleksbyte. */
  private val narrow = Var(dom.window.innerWidth < 640)

  // -- byggstenar -----------------------------------------------------------

  private def toggle[A](label: String, v: Var[A], opts: Seq[(A, String)]): HtmlElement =
    div(
      cls := "group",
      span(cls := "lbl", label),
      opts.map { (value, text) =>
        button(
          text,
          cls("on") <-- v.signal.map(_ == value),
          onClick.mapTo(value) --> v
        )
      }
    )

  /**
   * En ECharts-instans bunden till en option-signal. notMerge=true vid varje
   * uppdatering: reglagen byter serieuppsättning, och en sammanslagning skulle
   * lämna kvar serier från förra läget.
   */
  private def chartBox(opt: Signal[js.Any]): HtmlElement =
    var chart: Option[EChartsInstance] = None
    var onResize: Option[js.Function1[dom.Event, Unit]] = None
    div(
      cls := "chart",
      onMountBind { ctx =>
        // useDirtyRect: ett tryck i pristabellen försätter 27 av 28 serier i
        // blur-läge, och utan partiell omritning ritas hela duken om varje gång.
        val c = ECharts.init(ctx.thisNode.ref, null, js.Dynamic.literal(useDirtyRect = true))
        chart = Some(c)
        val h: js.Function1[dom.Event, Unit] = (_: dom.Event) => c.resize()
        dom.window.addEventListener("resize", h)
        onResize = Some(h)
        opt --> { o => c.setOption(o, true) }
      },
      onUnmountCallback { _ =>
        onResize.foreach(h => dom.window.removeEventListener("resize", h))
        chart.foreach(_.dispose())
        chart = None; onResize = None
      }
    )

  private def provenance(m: Data.Meta): HtmlElement =
    p(
      cls := "prov",
      s"Refreshed ${m.generated} · ",
      m.sources.map(s => span(a(href := s.url, target := "_blank", s.name), s" (${s.licence}) ")).toSeq
    )

  // -- vyer -----------------------------------------------------------------

  private def crackSection(c: Data.Cracks, dc: Data.DailyCracks): HtmlElement =
    // Vilken serie tröskelläget fyller. Härledd i stället för återställd: om
    // valet inte hör till regionen tas regionens första, så ett regionbyte
    // aldrig kan lämna ett omöjligt tillstånd efter sig.
    val selected: Signal[Option[Data.Crack]] =
      crackRegion.signal.combineWith(crackPick.signal).map { (region, pick) =>
        val ss = c.spreads(region)
        ss.find(_.key == pick).orElse(ss.headOption)
      }

    val weeklyOption: Signal[js.Any] =
      crackMode.signal
        .combineWith(crackRegion.signal, selected, threshold.signal)
        .map { (mode, region, sel, th) =>
          if mode == "line" then Charts.crackLine(c, region)
          else sel.fold(Charts.crackLine(c, region))(s => Charts.crackThreshold(c, s, th))
        }

    val option: Signal[js.Any] =
      crackScale.signal
        .combineWith(weeklyOption, crackRegion.signal, crackRuler.signal)
        .map { (scale, weekly, region, ruler) =>
          if scale == "daily" then Charts.crackDaily(dc, region, ruler) else weekly
        }

    // Tomläget gäller båda skalorna: NWE saknar källa i dag- såväl som veckofil.
    val hasDaily: Signal[Boolean] =
      crackScale.signal.combineWith(crackRegion.signal).map { (scale, r) =>
        if scale == "daily" then dc.spreads(r).exists(_.values.nonEmpty)
        else c.spreads(r).exists(_.values.nonEmpty)
      }

    div(
      idAttr := "cracks",
      h1("Diesel crack spreads"),
      p(
        "What a refiner earns per barrel turning crude into diesel. ",
        "The US legs come from EIA spot prices; the North-West European leg needs ",
        "ICE gasoil, which has no free API."
      ),
      p(
        cls := "prov",
        "Weekly points are averages of the trading days in an ISO week, and a week ",
        "with fewer than three published days is left blank rather than averaged as ",
        "if it were complete. Daily shows every EIA observation, with an optional ",
        "7-day ruler — the unweighted mean of the trailing seven calendar days, ",
        "which is one trading week. EIA publishes spot prices about a week in ",
        "arrears, so the last point is never today."
      ),
      div(
        cls := "controls",
        toggle("Region", crackRegion, Seq("US" -> "US (NYH)", "NWE" -> "NW Europe")),
        toggle("Scale", crackScale, Seq("weekly" -> "Weekly", "daily" -> "Daily")),
        // Linjalen finns bara i dagsläget: en 7-dagarslinjal över veckomedelvärden
        // hade jämnat ut ett redan utjämnat tal och sagt ingenting.
        child.maybe <-- crackScale.signal.map { sc =>
          Option.when(sc == "daily")(
            toggle("7-day ruler", crackRuler, Seq(true -> "On", false -> "Off"))
          )
        },
        // Tröskel- och linjeläget hör till veckoskalan.
        child.maybe <-- crackScale.signal.map { sc =>
          Option.when(sc == "weekly")(
            toggle("View", crackMode, Seq("threshold" -> "Threshold", "line" -> "Line"))
          )
        },
        // Seriepickern hör bara till tröskelläget, som fyller en serie i taget.
        child.maybe <-- crackMode.signal.combineWith(crackRegion.signal, crackScale.signal).map { (m, r, sc) =>
          val ss = c.spreads(r)
          Option.when(sc == "weekly" && m == "threshold" && ss.length > 1)(
            toggle("Series", crackPick, ss.map(s => s.key -> s.label))
          )
        },
        child.maybe <-- crackMode.signal.combineWith(crackScale.signal).map { (m, sc) =>
          Option.when(sc == "weekly" && m == "threshold")(
            div(
              cls := "group",
              span(cls := "lbl", "Threshold USD/bbl"),
              input(
                tpe := "number", stepAttr := "1",
                controlled(
                  value <-- threshold.signal.map(_.round.toString),
                  onInput.mapToValue.map(_.toDoubleOption.getOrElse(25.0)) --> threshold
                )
              ),
              input(
                tpe := "range", minAttr := "-10", maxAttr := "90", stepAttr := "1",
                controlled(
                  value <-- threshold.signal.map(_.round.toString),
                  onInput.mapToValue.map(_.toDoubleOption.getOrElse(25.0)) --> threshold
                )
              )
            )
          )
        },
        // Färskheten står bredvid reglagen, inte i en fotnot: meta.generated
        // säger när pipelinen kördes och säger ingenting om hur gammal datan är,
        // och det är precis den förväxlingen som fick en läsare att jämföra
        // veckosnittet med en dagskurs.
        child.maybe <-- crackScale.signal.map { sc =>
          Option.when(sc == "daily")(
            div(
              cls := "group",
              span(
                cls := "lbl",
                (dc.lastObservation, dc.lagDays) match
                  case (Some(last), Some(lag)) =>
                    s"Last EIA observation $last — $lag days before this refresh"
                  case (Some(last), None) => s"Last EIA observation $last"
                  case _                  => "No observations"
              )
            )
          )
        }
      ),
      child <-- hasDaily.map {
        case true => chartBox(option)
        case false =>
          div(
            cls := "empty",
            div(
              b("No ICE gasoil data supplied."),
              p(
                "ICE licenses Low Sulphur Gasoil settlements and offers no free API, so ",
                "the NW European crack cannot be built automatically. Add settlements to ",
                code("data/manual/ice_gasoil.csv"),
                " and rerun ", code("pipeline/run.sh"), " to populate this chart."
              )
            )
          )
      },
      provenance(c.meta)
    )

  private def retailSection(r: Data.Retails, fx: Data.Fx): HtmlElement =
    // Antal länder som saknar pris i det valda läget — utan skatt publicerar
    // inte alla källor, och en tyst lucka vore värre än en not.
    // Vilka länder som faller bort, inte hur många. "1 region(s) omitted" fick
    // en läsare att undra om USA-kurvan försvunnit av misstag — den ska namnge
    // landet och säga varför.
    val missing: Signal[Vector[String]] =
      retailFuel.signal.combineWith(retailTax.signal).map { (f, t) =>
        val everywhere = r.series.map(s => s.cc -> s.label).distinct.toMap
        val present    = r.pick(f, t).map(_.cc).toSet
        everywhere.view.filterKeys(!present.contains(_)).values.toVector.sorted
      }

    div(
      idAttr := "retail",
      h2("Retail diesel and petrol — Sweden against the EU-27 and the USA"),
      p(
        "Weekly pump prices per litre. Sweden is drawn bold, other EU members thin grey, ",
        "the USA dashed. Hover any line to lift it out of the pack."
      ),
      div(
        cls := "controls",
        toggle("Fuel", retailFuel, Seq("diesel" -> "Diesel", "gasoline" -> "Petrol (E95)")),
        toggle("Tax", retailTax, Seq("with" -> "With tax", "without" -> "Without tax")),
        toggle("Currency", retailCcy, Seq("EUR" -> "EUR", "USD" -> "USD", "SEK" -> "SEK"))
      ),
      // Ovanför diagrammet, inte under: noten ska synas i samma ögonkast som
      // reglaget man just tryckte på.
      child.maybe <-- missing.map { names =>
        Option.when(names.nonEmpty)(
          p(cls := "note-inline",
            b(names.mkString(", ")),
            if names.sizeIs == 1 then " is not shown here. " else " are not shown here. ",
            "The source publishes only a pump price for ",
            if names.sizeIs == 1 then "it" else "them",
            ", which already includes tax — there is no pre-tax series to draw. US fuel tax ",
            "is a fixed excise per gallon (18.4¢ petrol, 24.4¢ diesel federally, plus a state ",
            "tax that varies from a few cents to over 60¢), not a percentage, so it cannot be ",
            "backed out of the pump price without knowing the state: ",
            a(href := "https://en.wikipedia.org/wiki/Fuel_taxes_in_the_United_States",
              target := "_blank", "Fuel taxes in the United States"), "."
          )
        )
      },
      chartBox(
        retailFuel.signal
          .combineWith(retailTax.signal, retailCcy.signal, narrow.signal)
          .map((f, t, c, n) => Charts.retail(r, fx, f, t, c, n))
      ),
      provenance(r.meta)
    )

  private def usSection(g: Data.Regions, r: Data.Retails, fx: Data.Fx): HtmlElement =
    div(
      idAttr := "usregions",
      h2("How much one country varies — US pump prices by state and region"),
      p(
        "The single US line on the chart above is a national average, and averages hide things. ",
        "California against Texas is roughly a fifty-percent difference on the same fuel, and ",
        "most of it is tax: a state levy ranging from a few cents to over sixty cents a gallon, ",
        "on top of the federal excise."
      ),
      div(
        cls := "controls",
        toggle("Fuel", usFuel, Seq("gasoline" -> "Petrol (regular)", "diesel" -> "Diesel")),
        toggle("Currency", usCcy, Seq("USD" -> "USD", "EUR" -> "EUR", "SEK" -> "SEK"))
      ),
      // Geografin är inte densamma för de två bränslena, och det ska stå där man
      // byter bränsle — inte i en fotnot man ändå inte läser.
      child <-- usFuel.signal.map { f =>
        if g.geoOf(f) == "state" then
          p(cls := "note-inline",
            b("Nine states"), " — that is the whole of EIA's free state-level petrol coverage, ",
            "not a selection. The other forty-one are not published weekly.")
        else
          p(cls := "note-inline",
            b("Regions, not states"), " — EIA publishes weekly diesel by PADD refining region ",
            "rather than by state. California is the one state broken out separately.")
      },
      chartBox(
        usFuel.signal
          .combineWith(usCcy.signal, narrow.signal)
          .map { (f, c, n) =>
            val national = r.pick(f, "with").find(_.region == "US")
            Charts.usRegions(g, national, fx, f, c, n)
          }
      ),
      p(cls := "prov",
        "The US average is volume-weighted across the whole country, so it need not sit ",
        "midway between the lines drawn here."),
      provenance(g.meta)
    )

  private def dualSection(c: Data.Cracks, r: Data.Retails): HtmlElement =
    div(
      idAttr := "rockets",
      h2("Rockets and feathers — crude against the US pump"),
      p(
        "Crude benchmarks on the left axis, US retail on the right. Pump prices chase a ",
        "crude spike up within weeks and drift back down over months; the 2022 episode ",
        "shows the asymmetry plainly."
      ),
      chartBox(Signal.fromValue(Charts.rocketsFeathers(c, r))),
      provenance(c.meta)
    )

  private def notes: HtmlElement =
    div(
      cls := "notes",
      h2("How to read these charts"),
      ul(
        li(b("Crack spread"), " is the refining margin: the product price and the crude ",
           "price expressed in the same unit, subtracted. ",
           code("ULSD USD/gal × 42 − Brent USD/bbl"), ". 42 US gallons to the barrel is exact."),
        li(b("Threshold view"), " fills the area between the spread and a threshold you set — ",
           "green where the margin clears it, red where it does not. Set it to a refinery's ",
           "breakeven and the profitable stretches become scannable rather than readable."),
        li(b("The NW European crack"), " uses ", code("ICE gasoil USD/t ÷ 7.45 − Brent USD/bbl"), ". ",
           "7.45 barrels per tonne is a conventional density factor, not a definition — unlike ",
           "the gallon figure, it is an approximation."),
        li(b("Prices are per litre"), " and stored in their native currency: EUR for the EU ",
           "Oil Bulletin, USD for EIA. The currency toggle converts at the ECB reference rate ",
           "for that same week, not one rate applied across the whole series."),
        li(b("Why the US line sits so low."), " It is not cheaper crude — the same barrels ",
           "feed both markets. It is tax. US fuel tax is a fixed cents-per-gallon excise: ",
           "18.4¢/gal on petrol and 24.4¢/gal on diesel federally, plus a state tax that ",
           "averages roughly 30¢/gal but ranges from a few cents to over 60¢. Together that ",
           "is on the order of 0.1–0.2 EUR/L. EU member states levy excise several times ",
           "larger and then apply VAT on top of it, which is why the gap is closer to 1 EUR/L ",
           "than to the difference in the product itself. ",
           a(href := "https://en.wikipedia.org/wiki/Fuel_taxes_in_the_United_States",
             target := "_blank", "Fuel taxes in the United States"), "."),
        li(b("Gaps are gaps."), " A week with no observation is drawn as a break. Nothing is ",
           "interpolated or carried forward — except exchange rates over bank holidays, where ",
           "a rate genuinely persists until it is restated.")
      )
    )

  // -- start ----------------------------------------------------------------

  def main(args: Array[String]): Unit =
    import Data.given
    val mount = dom.document.getElementById("app")

    val loaded =
      for
        c  <- Data.cracks(DataBase)
        dc <- Data.cracksDaily(DataBase)
        r  <- Data.retail(DataBase)
        fx <- Data.fx(DataBase)
        g  <- Data.usregions(DataBase)
      yield (c, dc, r, fx, g)

    loaded.onComplete {
      case Success((c, dc, r, fx, g)) =>
        mount.innerHTML = ""
        render(mount, div(crackSection(c, dc), retailSection(r, fx),
                          usSection(g, r, fx), dualSection(c, r), notes))
        // Ankaret hinner inte finnas när webbläsaren försöker hoppa dit: appen
        // renderas först när de tre JSON-filerna kommit. Utan detta gör en delad
        // länk till #retail eller #rockets ingenting alls.
        dom.window.addEventListener("resize",
          (_: dom.Event) => narrow.set(dom.window.innerWidth < 640))
        val hash = dom.window.location.hash
        if hash.length > 1 then
          Option(dom.document.getElementById(hash.drop(1)))
            .foreach(_.scrollIntoView())
      case Failure(e) =>
        mount.innerHTML = ""
        render(
          mount,
          p(cls := "failed",
            "Could not load the published data: ", e.getMessage, ". ",
            "Serve the site over HTTP (not file://) and check that ",
            code("site/public/data/"), " contains the JSON files.")
        )
    }
