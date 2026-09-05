package com.example.aichat

import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.StrictMode
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    // v1.7.24（十大维度·性能）：Debug 下开启 StrictMode 主线程磁盘/网络访问监控，
    // 提前抓出卡顿根因（主线程 IO / 泄漏的 SQLite/Closable/Activity）。
    override fun onCreate(savedInstanceState: Bundle?) {
        val isDebug = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (isDebug) {
            StrictMode.setThreadPolicy(
                StrictMode.ThreadPolicy.Builder()
                    .detectDiskReads()
                    .detectDiskWrites()
                    .detectNetwork()
                    .penaltyLog()
                    .build()
            )
            StrictMode.setVmPolicy(
                StrictMode.VmPolicy.Builder()
                    .detectLeakedSqlLiteObjects()
                    .detectLeakedClosableObjects()
                    .detectActivityLeaks()
                    .penaltyLog()
                    .build()
            )
        }
        super.onCreate(savedInstanceState)
    }
}
