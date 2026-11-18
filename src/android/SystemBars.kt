// HollerShare's own Android source: the status and navigation bars in the
// page's colours (build.zig registers it as an Android platform hook).
// Android 15 draws apps edge to edge and ignores window.statusBarColor, so
// Oriel's theme-color leaves the bars in the default grey with light icons,
// unreadable on the light page. This paints the window behind the bars in
// the page's background and picks dark or light icons from the system theme
// the page follows.
package dev.hollershare

import android.app.Activity
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsetsController
import androidx.annotation.Keep
import dev.oriel.OrielAndroidHooks

@Keep
class SystemBars : OrielAndroidHooks {
    private companion object {
        /** frontend/style.css --paper, light and dark. */
        const val LIGHT_PAPER = 0xFFF5F1E9.toInt()
        const val DARK_PAPER = 0xFF1A1714.toInt()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = apply(activity, activity.resources.configuration)
    override fun onActivityResumed(activity: Activity) = apply(activity, activity.resources.configuration)
    override fun onConfigurationChanged(activity: Activity, configuration: Configuration) = apply(activity, configuration)

    private fun apply(activity: Activity, configuration: Configuration) {
        val dark = configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val paper = if (dark) DARK_PAPER else LIGHT_PAPER
        val window = activity.window
        // Behind the bars (edge to edge, Android 15+), and the bars
        // themselves on older versions.
        window.setBackgroundDrawable(ColorDrawable(paper))
        window.decorView.setBackgroundColor(paper)
        @Suppress("DEPRECATION")
        run {
            window.statusBarColor = paper
            window.navigationBarColor = paper
        }
        val lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.setSystemBarsAppearance(if (dark) 0 else lightBars, lightBars)
        } else {
            // Android 10: the same dark icons through the older flags.
            @Suppress("DEPRECATION")
            run {
                val flags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
                val decor = window.decorView
                decor.systemUiVisibility = if (dark) decor.systemUiVisibility and flags.inv() else decor.systemUiVisibility or flags
            }
        }
    }
}
