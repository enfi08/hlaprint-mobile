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
                                val copies = args["copies"] as Int

                                val pageStart = args["pageStart"] as Int?

                                val pageEnd = args["pageEnd"] as Int?

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
                                println("Copies = $copies")
                                println("pageStart = $pageStart")
                                println("pageEnd = $pageEnd")
                                printPdfDirectIPP(
                                    pdfFile = pdfFile,
                                    printerIp = ip,
                                    orientation = orientation,
                                    duplex = duplex,
                                    copies = copies,
                                    colorMode = colorMode,
                                    pageStart = pageStart,
                                    pageEnd = pageEnd,
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

                        Thread {
                            try {
                                val pdfFile = File(filePath)
                                printPdfDirectIPP(
                                    pdfFile = pdfFile,
                                    printerIp = printerIp,
                                    orientation = orientation,
                                    duplex = duplex,
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
        copies: Int = 1,
        colorMode: String = "monochrome",
        pageStart: Int? = null,
        pageEnd: Int? = null,
    ) {
        try {
            val printFile = if (pageStart != null && pageEnd != null) {
                val extractedPdf = File(cacheDir, "page_range_${pageStart}_$pageEnd.pdf")
                println("📄 Extracting pages $pageStart-$pageEnd → ${extractedPdf.path}")
                extractPagesVector(pdfFile, extractedPdf, pageStart, pageEnd)
                extractedPdf
            } else {
                pdfFile
            }

            val ippUrl = "ipp://$printerIp:631/ipp/print"
            val printerUri = URI.create(ippUrl)
            val printer = IppPrinter(printerUri)

            val job = printer.printJob(
                printFile,
                IppAttribute("job-name", IppTag.NameWithoutLanguage, IppString("IPP_Print_PDF")),
                IppAttribute("document-format", IppTag.MimeMediaType, "application/pdf"),
                IppAttribute("copies", IppTag.Integer, copies),
                IppAttribute("sides", IppTag.Keyword, if (duplex) "two-sided-long-edge" else "one-sided"),
                IppAttribute("orientation-requested", IppTag.Enum, orientation),
                IppAttribute("print-color-mode", IppTag.Keyword, colorMode),
                IppAttribute("print-quality", IppTag.Enum, 4),
                IppAttribute("media", IppTag.Keyword, "iso_a4_210x297mm"),
                IppAttribute("print-scaling", IppTag.Keyword, "none")
            )
            println("✅ Job submitted: ${job.id}")
            //  Thread.sleep(2000)

//        val jobAttrs = job.printerAttributes
//        val jobState = jobAttrs["job-state"]?.value ?: "unknown"
//        val jobStateMsg = jobAttrs["job-state-message"]?.value ?: "-"
//        jobAttrs.forEach { attr ->
//            println("${attr.key} → ${attr.value}")
//        }
//        println("🖨 Job state: $jobState / $jobStateMsg")
//
//        jobAttrs.forEach { (name, attr) ->
//            println("   $name → ${attr.value}")
//        }
//
//        if (jobState.toString().lowercase() != "completed") {
//            println("⚠️ Print belum selesai: State=$jobState Message=$jobStateMsg")
//        } else {
//            println("🎉 Print halaman pertama berhasil!")
//        }
        } catch (e: Exception) {
            println("❌ printPdfDirectIPP error: ${e.message}")
            throw e
        }
    }

    private fun extractPagesVector(input: File, output: File, pageStart: Int, pageEnd: Int) {
        val src = PDDocument.load(input)
        val newDoc = PDDocument()

        try {
            val totalPages = src.numberOfPages
            val start = pageStart.coerceAtLeast(1)
            val end = pageEnd.coerceAtMost(totalPages)

            if (start > end) {
                println("⚠️ Invalid page range: start=$start > end=$end")
            } else {
                for (pageIndex in start..end) {
                    if (pageIndex - 1 < totalPages) {
                        val page = src.getPage(pageIndex - 1)
                        newDoc.addPage(page)
                    }
                }
            }

            newDoc.save(output)
            println("✅ Extracted pages $start-$end to ${output.path}")
        } catch (e: Exception) {
            e.printStackTrace()
            println("❌ extractPagesVector failed: ${e.message}")
        } finally {
            newDoc.close()
            src.close()
        }
    }

}
