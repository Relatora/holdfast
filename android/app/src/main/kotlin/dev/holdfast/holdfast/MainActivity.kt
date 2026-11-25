package dev.holdfast.holdfast

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.CellIdentityGsm
import android.telephony.CellIdentityLte
import android.telephony.CellIdentityNr
import android.telephony.CellIdentityTdscdma
import android.telephony.CellIdentityWcdma
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoTdscdma
import android.telephony.CellInfoWcdma
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Holdfast's Flutter host, plus one native call: the cell towers the phone
 * can hear, for offline positioning when GPS can't get a fix.
 *
 * Channel `holdfast/cells`, method `scan`: a list of maps with `radio`
 * (gsm, umts, lte, nr), `mcc`, `mnc`, `area` (LAC or TAC), `cell`, `dbm`
 * (may be absent) and `serving`. Cells without a full identity (neighbours
 * often report only a physical id) are left out: they can't be looked up.
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "holdfast/cells").setMethodCallHandler { call, result ->
            if (call.method != "scan") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                result.success(emptyList<Map<String, Any>>())
                return@setMethodCallHandler
            }
            val telephony = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager?
            if (telephony == null) {
                result.success(emptyList<Map<String, Any>>())
                return@setMethodCallHandler
            }
            scan(telephony) { cells -> runOnUiThread { result.success(cells) } }
        }
    }

    /**
     * Android 10+ caches cell info; ask the modem for a fresh reading, and
     * fall back to the cached one if it doesn't answer.
     */
    @Suppress("MissingPermission") // checked by the caller
    private fun scan(telephony: TelephonyManager, done: (List<Map<String, Any>>) -> Unit) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                telephony.requestCellInfoUpdate(
                    Executors.newSingleThreadExecutor(),
                    object : TelephonyManager.CellInfoCallback() {
                        override fun onCellInfo(cellInfo: MutableList<CellInfo>) = done(describe(cellInfo))
                        override fun onError(errorCode: Int, detail: Throwable?) =
                            done(describe(telephony.allCellInfo.orEmpty()))
                    },
                )
            } else {
                done(describe(telephony.allCellInfo.orEmpty()))
            }
        } catch (_: SecurityException) {
            done(emptyList()) // location switched off, or permission revoked
        }
    }

    private fun describe(cells: List<CellInfo>): List<Map<String, Any>> = cells.mapNotNull { info ->
        val (radio, ids, dbm) = when (info) {
            is CellInfoLte -> Triple("lte", lte(info.cellIdentity), info.cellSignalStrength.dbm)
            is CellInfoGsm -> Triple("gsm", gsm(info.cellIdentity), info.cellSignalStrength.dbm)
            is CellInfoWcdma -> Triple("umts", wcdma(info.cellIdentity), info.cellSignalStrength.dbm)
            else -> when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info is CellInfoNr ->
                    Triple("nr", nr(info.cellIdentity as CellIdentityNr), info.cellSignalStrength.dbm)
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info is CellInfoTdscdma ->
                    // OpenCelliD files TD-SCDMA under UMTS.
                    Triple("umts", tdscdma(info.cellIdentity), info.cellSignalStrength.dbm)
                else -> return@mapNotNull null
            }
        }
        if (ids == null) return@mapNotNull null
        val cell = mutableMapOf<String, Any>(
            "radio" to radio,
            "mcc" to ids[0],
            "mnc" to ids[1],
            "area" to ids[2],
            "cell" to ids[3],
            "serving" to info.isRegistered,
        )
        if (dbm != Int.MAX_VALUE && dbm < 0) cell["dbm"] = dbm
        cell
    }

    // Each returns [mcc, mnc, area, cell], or null when any part is unknown
    // (Android reports unknown values as Int.MAX_VALUE or a null string).

    private fun lte(id: CellIdentityLte) = full(id.mccString, id.mncString, id.tac.toLong(), id.ci.toLong())

    private fun gsm(id: CellIdentityGsm) = full(id.mccString, id.mncString, id.lac.toLong(), id.cid.toLong())

    private fun wcdma(id: CellIdentityWcdma) = full(id.mccString, id.mncString, id.lac.toLong(), id.cid.toLong())

    private fun tdscdma(id: CellIdentityTdscdma) = full(id.mccString, id.mncString, id.lac.toLong(), id.cid.toLong())

    private fun nr(id: CellIdentityNr) = full(id.mccString, id.mncString, id.tac.toLong(), id.nci)

    private fun full(mcc: String?, mnc: String?, area: Long, cell: Long): List<Long>? {
        val mccValue = mcc?.toLongOrNull() ?: return null
        val mncValue = mnc?.toLongOrNull() ?: return null
        if (area <= 0 || area == Int.MAX_VALUE.toLong() || cell <= 0 || cell == Int.MAX_VALUE.toLong() ||
            cell == Long.MAX_VALUE
        ) {
            return null
        }
        return listOf(mccValue, mncValue, area, cell)
    }
}
