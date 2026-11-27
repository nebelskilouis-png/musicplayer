package com.example.musicplayer

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView

/** Kleine Helfer für die Uhr-Oberfläche (ohne XML-Layouts). */
object Ui {
    const val BG = 0xFF000000.toInt()
    const val ACCENT = 0xFF1E50E0.toInt()
    const val LIGHT = 0xFF5B8CFF.toInt()
    const val GREY = 0xFFB3B3B3.toInt()
    const val ROW = 0xFF1C2B4F.toInt()
    const val ELEVATED = 0xFF282828.toInt()

    fun dp(c: Context, v: Int) = (v * c.resources.displayMetrics.density).toInt()

    fun text(
        c: Context,
        s: String,
        sp: Float,
        color: Int = Color.WHITE,
        bold: Boolean = false,
        lines: Int = 1,
    ) = TextView(c).apply {
        text = s
        textSize = sp
        setTextColor(color)
        gravity = Gravity.CENTER
        maxLines = lines
        ellipsize = TextUtils.TruncateAt.END
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    fun oval(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    fun rounded(c: Context, color: Int, radiusDp: Int = 24) = GradientDrawable().apply {
        cornerRadius = dp(c, radiusDp).toFloat()
        setColor(color)
    }

    fun haptic(v: View) {
        v.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY)
    }

    /** Runder Knopf mit System-Symbol. */
    fun iconButton(c: Context, res: Int, sizeDp: Int, filled: Boolean, onClick: (View) -> Unit) =
        ImageButton(c).apply {
            setImageResource(res)
            setColorFilter(Color.WHITE)
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
            val pad = dp(c, sizeDp / 5)
            setPadding(pad, pad, pad, pad)
            background = oval(if (filled) ACCENT else 0x33FFFFFF)
            layoutParams = LinearLayout.LayoutParams(dp(c, sizeDp), dp(c, sizeDp)).apply {
                setMargins(dp(c, 4), 0, dp(c, 4), 0)
            }
            setOnClickListener { haptic(it); onClick(it) }
        }

    /** Runder Knopf mit Text/Zeichen. */
    fun textButton(c: Context, label: String, sizeDp: Int, sp: Float, onClick: (View) -> Unit) =
        text(c, label, sp, bold = true).apply {
            background = oval(0x33FFFFFF)
            layoutParams = LinearLayout.LayoutParams(dp(c, sizeDp), dp(c, sizeDp)).apply {
                setMargins(dp(c, 6), 0, dp(c, 6), 0)
            }
            setOnClickListener { haptic(it); onClick(it) }
        }

    /** Breiter Knopf mit Text. */
    fun pill(c: Context, label: String, color: Int = ROW, onClick: (View) -> Unit) =
        text(c, label, 15f, bold = true).apply {
            background = rounded(c, color)
            setPadding(dp(c, 16), dp(c, 12), dp(c, 16), dp(c, 12))
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { setMargins(dp(c, 18), dp(c, 5), dp(c, 18), dp(c, 5)) }
            setOnClickListener { haptic(it); onClick(it) }
        }

    fun row(c: Context, horizontal: Boolean = true) = LinearLayout(c).apply {
        orientation = if (horizontal) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        gravity = Gravity.CENTER
    }

    /** Mit der Krone scrollen. */
    fun enableRotary(v: View, scroll: (Int) -> Unit) {
        v.isFocusable = true
        v.isFocusableInTouchMode = true
        v.setOnGenericMotionListener { view, ev ->
            if (ev.action == MotionEvent.ACTION_SCROLL && ev.isFromSource(InputDevice.SOURCE_ROTARY_ENCODER)) {
                val f = ViewConfiguration.get(view.context).scaledVerticalScrollFactor
                scroll((-ev.getAxisValue(MotionEvent.AXIS_SCROLL) * f).toInt())
                true
            } else {
                false
            }
        }
        v.requestFocus()
    }
}

/** Eine Zeile in einer Liste. */
data class Row(
    val title: String,
    val sub: String? = null,
    val header: Boolean = false,
    val highlight: Boolean = false,
    val dim: Boolean = false,
)

/** Einfache, rund-taugliche Liste mit Kronen-Scrollen. */
class RowList(private val activity: Activity, title: String) {
    private var rows: List<Row> = emptyList()
    var onClick: (Int) -> Unit = {}

    private val adapter = object : BaseAdapter() {
        override fun getCount() = rows.size
        override fun getItem(position: Int) = rows[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val r = rows[position]
            val c = activity
            val box = (convertView as? LinearLayout) ?: LinearLayout(c).apply {
                orientation = LinearLayout.VERTICAL
                addView(Ui.text(c, "", 15f).apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL })
                addView(Ui.text(c, "", 12f, Ui.GREY).apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL })
            }
            val t = box.getChildAt(0) as TextView
            val s = box.getChildAt(1) as TextView
            t.text = r.title
            t.setTextColor(if (r.highlight || r.header) Ui.LIGHT else Color.WHITE)
            t.typeface = if (r.header) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
            t.textSize = if (r.header) 14f else 15f
            s.text = r.sub ?: ""
            s.visibility = if (r.sub.isNullOrEmpty()) View.GONE else View.VISIBLE
            box.alpha = if (r.dim) 0.45f else 1f
            val p = Ui.dp(c, 10)
            box.setPadding(Ui.dp(c, 18), p, Ui.dp(c, 18), p)
            box.background = if (r.header) Ui.rounded(c, Ui.ELEVATED, 12) else null
            return box
        }
    }

    val view: ListView = ListView(activity).apply {
        setBackgroundColor(Ui.BG)
        divider = null
        dividerHeight = Ui.dp(activity, 2)
        val side = Ui.dp(activity, 12)
        val h = activity.resources.displayMetrics.heightPixels
        setPadding(side, h / 6, side, h / 4)
        clipToPadding = false
        isVerticalScrollBarEnabled = true
        addHeaderView(Ui.text(activity, title, 16f, Ui.LIGHT, bold = true).apply {
            setPadding(0, 0, 0, Ui.dp(activity, 8))
        }, null, false)
        this.adapter = this@RowList.adapter
        setOnItemClickListener { _, v, pos, _ ->
            val i = pos - headerViewsCount
            if (i in rows.indices) {
                Ui.haptic(v)
                onClick(i)
            }
        }
    }

    init {
        Ui.enableRotary(view) { view.scrollListBy(it) }
    }

    fun set(list: List<Row>) {
        rows = list
        adapter.notifyDataSetChanged()
    }

    fun scrollTo(i: Int) {
        if (i in rows.indices) view.setSelectionFromTop(i + view.headerViewsCount, activity.resources.displayMetrics.heightPixels / 4)
    }
}
