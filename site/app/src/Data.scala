package crack

import org.scalajs.dom
import scala.concurrent.{Future, ExecutionContext}
import scala.scalajs.js

/**
 * Avkodning av de tre publicerade JSON-filerna. Kontraktet ligger i
 * specs/001-crack-and-retail-fuel-site/contracts/chart-json.md — ändra inte
 * fältnamnen här utan att ändra 50_export.sql i samma commit.
 *
 * Formen är bred: en gemensam veckoaxel och positionellt uppradade values[].
 * Alla tre filerna delar samma veckoaxel per konstruktion, så indexering på
 * position är giltig och slipper datummatchning.
 */
object Data:
  given ExecutionContext = scala.scalajs.concurrent.JSExecutionContext.queue

  /** Ett värde saknas -> None. Aldrig 0, aldrig framskrivet. */
  type Series = Vector[Option[Double]]

  final case class Source(name: String, url: String, licence: String)
  final case class Meta(generated: String, sources: Vector[Source])

  final case class Crack(
      key: String, label: String, kind: String,
      region: String, unit: String, values: Series
  )
  final case class Cracks(meta: Meta, weeks: Vector[String], series: Vector[Crack]):
    def spreads(region: String): Vector[Crack] =
      series.filter(s => s.kind == "spread" && s.region == region)
    def level(key: String): Option[Crack] =
      series.find(s => s.kind == "level" && s.key == key)

  /**
   * Dagsfilen. Egen axel — `days` är observationsdatum, inte en kalender — och
   * den får INTE indexeras mot `weeks` i de andra filerna. Det är därför den är
   * en egen typ med ett eget axelfält i stället för ännu en Cracks.
   *
   * `of` binder en linjal till serien den jämnar ut, så inget behöver läsas ur
   * seriens namn.
   */
  final case class Daily(
      key: String, label: String, kind: String,
      region: String, unit: String, of: Option[String], values: Series
  )
  final case class DailyCracks(meta: Meta, days: Vector[String], series: Vector[Daily]):
    def spreads(region: String): Vector[Daily] =
      series.filter(s => s.kind == "spread" && s.region == region)
    def ma(key: String): Option[Daily] =
      series.find(s => s.kind == "ma" && s.of.contains(key))

    /** Sista dagen med en observation i någon spread — inte sista dagen i axeln. */
    def lastObservation: Option[String] =
      val idx = series
        .filter(_.kind == "spread")
        .flatMap(s => s.values.zipWithIndex.collect { case (Some(_), i) => i })
      Option.when(idx.nonEmpty)(days(idx.max))

    /**
     * Dygn mellan sista observationen och körningen. EIA ligger normalt ~8 dagar
     * efter, och det syns ingenstans i meta.generated — den säger när pipelinen
     * kördes, inte hur färsk datan är. Skillnaden är hela poängen med att skriva
     * ut den.
     */
    def lagDays: Option[Int] =
      lastObservation.map { last =>
        val ms = js.Date.parse(meta.generated) - js.Date.parse(last)
        math.round(ms / 86400000.0).toInt
      }

  final case class Retail(
      cc: String, label: String, region: String, focus: Boolean,
      fuel: String, tax: String, currency: String, values: Series
  )
  final case class Retails(meta: Meta, weeks: Vector[String], series: Vector[Retail]):
    def pick(fuel: String, tax: String): Vector[Retail] =
      series.filter(s => s.fuel == fuel && s.tax == tax)

  final case class Region(
      code: String, label: String, geo: String,
      fuel: String, currency: String, values: Series
  )
  final case class Regions(meta: Meta, weeks: Vector[String], regions: Vector[Region]):
    def pick(fuel: String): Vector[Region] = regions.filter(_.fuel == fuel)
    /** 'state' eller 'padd' — geografin skiljer sig mellan bränslena. */
    def geoOf(fuel: String): String =
      if pick(fuel).forall(_.geo == "state") then "state" else "padd"

  final case class Fx(meta: Meta, weeks: Vector[String], usd: Vector[Double], sek: Vector[Double]):
    /**
     * Växlar ett värde för vecka `i`. Serierna publiceras i sin ursprungsvaluta
     * och räknas om här — en sanning i pipelinen slår tre separat avrundade.
     */
    def convert(v: Double, from: String, to: String, i: Int): Double =
      val eur = if from == "USD" then v / usd(i) else v
      to match
        case "USD" => eur * usd(i)
        case "SEK" => eur * sek(i)
        case _     => eur

  // -- avkodning ------------------------------------------------------------
  // js.Dynamic direkt mot JSON.parse. Ett decode-bibliotek vore mer maskineri
  // än de tre formerna här motiverar.

  private def str(d: js.Dynamic): String  = d.asInstanceOf[String]
  private def num(d: js.Dynamic): Double  = d.asInstanceOf[Double]
  private def arr(d: js.Dynamic): Vector[js.Dynamic] =
    d.asInstanceOf[js.Array[js.Dynamic]].toVector

  private def series(d: js.Dynamic): Series =
    if js.isUndefined(d) || d == null then Vector.empty
    else
      arr(d).map(v => if v == null || js.isUndefined(v) then None else Some(num(v)))

  private def plain(d: js.Dynamic): Vector[Double] = arr(d).map(num)

  private def meta(d: js.Dynamic): Meta =
    Meta(
      generated = str(d.generated),
      sources = arr(d.sources).map(s => Source(str(s.name), str(s.url), str(s.licence)))
    )

  private def fetchJson(path: String): Future[js.Dynamic] =
    dom
      .fetch(path)
      .toFuture
      .flatMap { r =>
        if !r.ok then Future.failed(RuntimeException(s"$path: HTTP ${r.status}"))
        else r.text().toFuture
      }
      .map(t => js.JSON.parse(t))

  def cracks(base: String): Future[Cracks] =
    fetchJson(s"$base/cracks.json").map { d =>
      Cracks(
        meta(d.meta),
        arr(d.weeks).map(str),
        arr(d.series).map(s =>
          Crack(str(s.key), str(s.label), str(s.kind), str(s.region), str(s.unit), series(s.values))
        )
      )
    }

  def cracksDaily(base: String): Future[DailyCracks] =
    fetchJson(s"$base/cracks_daily.json").map { d =>
      DailyCracks(
        meta(d.meta),
        arr(d.days).map(str),
        arr(d.series).map(s =>
          Daily(
            str(s.key), str(s.label), str(s.kind), str(s.region), str(s.unit),
            if s.of == null || js.isUndefined(s.of) then None else Some(str(s.of)),
            series(s.values)
          )
        )
      )
    }

  def retail(base: String): Future[Retails] =
    fetchJson(s"$base/retail.json").map { d =>
      Retails(
        meta(d.meta),
        arr(d.weeks).map(str),
        arr(d.series).map(s =>
          Retail(
            str(s.cc), str(s.label), str(s.region),
            s.focus.asInstanceOf[Boolean],
            str(s.fuel), str(s.tax), str(s.currency), series(s.values)
          )
        )
      )
    }

  def usregions(base: String): Future[Regions] =
    fetchJson(s"$base/usregions.json").map { d =>
      Regions(
        meta(d.meta),
        arr(d.weeks).map(str),
        arr(d.regions).map(x =>
          Region(str(x.code), str(x.label), str(x.geo), str(x.fuel),
                 str(x.currency), series(x.values))
        )
      )
    }

  def fx(base: String): Future[Fx] =
    fetchJson(s"$base/fx.json").map { d =>
      Fx(meta(d.meta), arr(d.weeks).map(str), plain(d.rates.USD), plain(d.rates.SEK))
    }
