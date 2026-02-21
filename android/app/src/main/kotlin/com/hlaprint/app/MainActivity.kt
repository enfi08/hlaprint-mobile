package com.hlaprint.app

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.net.URI
import android.os.Bundle
import de.gmuth.ipp.client.IppPrinter
import de.gmuth.ipp.core.IppAttribute
import de.gmuth.ipp.core.IppTag
import de.gmuth.ipp.core.IppString
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument


class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.hlaprint.app/printing"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "printPDF" -> {
                        println("Print PDF")
                        val args = call.arguments as Map<String, Any>
                        Thread {
                            try {
                                val filePath = args["filePath"] as String
                                val ip = args["ip"] as String
                                var orientation = args["orientation"] as Int
                                val colorMode = args["color"] as String
                                val duplex = args["duplex"] as Boolean
                                val pageSize = args["pageSize"] as? String ?: "A4"
                                val copies = args["copies"] as? Int ?: 1

                                val pdfFile = File(filePath)
                                if (orientation == -1) {  // berarti "auto"
                                    orientation = detectPdfOrientation(pdfFile)
                                    println("🔁 Auto orientation = $orientation")
                                }
                                println("🔍 Printing:")
                                println("IP = $ip")
                                println("Duplex = $duplex")
                                println("Color = $colorMode")
                                println("Orientation = $orientation")
                                printPdfDirectIPP(
                                    pdfFile = pdfFile,
                                    printerIp = ip,
                                    orientation = orientation,
                                    duplex = duplex,
                                    colorMode = colorMode,
                                    pageSize = pageSize,
                                    copies = copies
                                )
                                result.success("success")
                            } catch (e: Exception) {
                                e.printStackTrace()
                                result.error("IPP_ERROR", e.message, null)
                            }
                        }.start()
                    }
                    "printInvoicePdf" -> {
                        val filePath = call.argument<String>("filePath")
                        val printerIp = call.argument<String>("ip")

                        if (filePath == null || printerIp == null) {
                            result.success("error:missing-params")
                            return@setMethodCallHandler
                        }
                        val orientation = call.argument<Int>("orientation") ?: 3     // 3 = portrait (IPP enum)
                        val duplex = call.argument<Boolean>("duplex") ?: false

                        val pageSize = call.argument<String>("pageSize") ?: "A4"

                        Thread {
                            try {
                                val pdfFile = File(filePath)
                                printPdfDirectIPP(
                                    pdfFile = pdfFile,
                                    printerIp = printerIp,
                                    orientation = orientation,
                                    duplex = duplex,
                                    pageSize = pageSize
                                )
                                result.success("success")
                            } catch (e: Exception) {
                                result.success("error:${e.message}")
                            }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PDFBoxResourceLoader.init(applicationContext)
    }


    fun detectPdfOrientation(pdf: File): Int {
        val doc = PDDocument.load(pdf)
        val page = doc.getPage(0)

        val mediaBox = page.mediaBox
        val width = mediaBox.width
        val height = mediaBox.height

        doc.close()

        return if (width > height) 4 else 3
    }


    private fun printPdfDirectIPP(
        pdfFile: File,
        printerIp: String,
        orientation: Int,
        duplex: Boolean,
        colorMode: String = "monochrome",
        pageSize: String = "A4",
        copies: Int = 1,
    ) {
        try {
            val ippUrl = "ipp://$printerIp:631/ipp/print"
            val printerUri = URI.create(ippUrl)
            val printer = IppPrinter(printerUri)
            val mediaSizeKeyword = when (pageSize.uppercase()) {
                "A4" -> "iso_a4_210x297mm"
                "LETTER" -> "na_letter_8.5x11in"
                "LEGAL" -> "na_legal_8.5x14in"
                "A3" -> "iso_a3_297x420mm"
                "A5" -> "iso_a5_148x210mm"
                "F4" -> "om_f4_210x330mm"
                else -> "iso_a4_210x297mm"
            }

            val job = printer.printJob(
                pdfFile,
                IppAttribute("job-name", IppTag.NameWithoutLanguage, IppString("IPP_Print_PDF")),
                IppAttribute("document-format", IppTag.MimeMediaType, "application/pdf"),
                IppAttribute("copies", IppTag.Integer, copies),
                IppAttribute("sides", IppTag.Keyword, if (duplex) "two-sided-long-edge" else "one-sided"),
                IppAttribute("orientation-requested", IppTag.Enum, orientation),
                IppAttribute("print-color-mode", IppTag.Keyword, colorMode),
                IppAttribute("print-quality", IppTag.Enum, 4),
                IppAttribute("media", IppTag.Keyword, mediaSizeKeyword),
                IppAttribute("print-scaling", IppTag.Keyword, "auto-fit")
            )
            println("✅ Job submitted: ${job.id}")
        } catch (e: Exception) {
            println("❌ error: ${e.message}")
            throw e
        }
    }

}
