package com.github.lingyan000.fluxdo

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// 切换站点用的跳板：跑在独立进程（manifest 里 android:process=":site_restart"），
/// 主进程把自己退掉之后由它重新拉起 MainActivity，再把自己这个进程也退掉。
/// 不能在主进程里原地 recreate()，原因见 MainActivity.restartForSite。
class SiteRestartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        )
        finish()
        Runtime.getRuntime().exit(0)
    }
}
