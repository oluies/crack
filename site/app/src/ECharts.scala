package crack

import org.scalajs.dom
import scala.scalajs.js
import scala.scalajs.js.annotation.*

/**
 * Minimal handskriven fasad mot ECharts (global från script-taggen i index.html).
 * Bara de medlemmar diagrammen faktiskt anropar — lägg till fler när ett diagram
 * behöver dem, aldrig i förväg. Byt mot ScalablyTyped först om typade options
 * blir ett verkligt behov.
 */
@js.native
@JSGlobal("echarts")
object ECharts extends js.Object:
  def init(el: dom.Element): EChartsInstance = js.native
  /** Med opts: useDirtyRect begränsar omritningen till det som faktiskt ändrats,
    * vilket är skillnaden mellan segt och obrukbart på telefon när ett tryck
    * försätter 27 av 28 serier i blur-läge. */
  def init(el: dom.Element, theme: js.Any, opts: js.Any): EChartsInstance = js.native

@js.native
trait EChartsInstance extends js.Object:
  def setOption(option: js.Any): Unit                             = js.native
  def setOption(option: js.Any, notMerge: Boolean): Unit          = js.native
  def resize(): Unit                                              = js.native
  def on(event: String, handler: js.Function1[js.Dynamic, Unit]): Unit = js.native
  def dispose(): Unit                                             = js.native
