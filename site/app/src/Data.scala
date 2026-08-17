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

  final case class Retail(
      cc: String, label: String, region: String, focus: Boolean,
      fuel: String, tax: String, currency: String, values: Series
  )
  final case class Retails(meta: Meta, weeks: Vector[String], series: Vector[Retail]):
    def pick(fuel: String, tax: String): Vector[Retail] =
      series.filter(s => s.fuel == fuel && s.tax == tax)

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

  def fx(base: String): Future[Fx] =
    fetchJson(s"$base/fx.json").map { d =>
      Fx(meta(d.meta), arr(d.weeks).map(str), plain(d.rates.USD), plain(d.rates.SEK))
    }
