#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winspool.h>
#include <shlobj.h>
#include <string>
#include <thread>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <algorithm>
#include <glib.h>
#include <poppler/glib/poppler.h>
#include <cairo/cairo-win32.h>
#include "flutter_window.h"
#include "utils.h"

#define WM_FLUTTER_PRINT_EVENT (WM_USER + 101)

std::unique_ptr<flutter::MethodChannel<>> g_channel;

struct PrintEventData {
    int type; // 1 = Job Completed, 2 = Status Update
    int printJobId;
    int totalPages;
    std::string statusMsg;
};

DWORD g_mainThreadId = 0;
HWND g_mainWindowHandle = nullptr;

void LogStatus(std::string msg) {
    auto t = std::time(nullptr);
    struct tm tm;
    localtime_s(&tm, &t);
    std::cout << "[PrintMonitor " << std::put_time(&tm, "%H:%M:%S") << "] " << msg << std::endl;
    OutputDebugStringA(("[PrintMonitor] " + msg + "\n").c_str());
}

void MonitorPrintJob(HANDLE hPrinter, DWORD winJobId, int appPrintJobId, int totalPages) {
    OutputDebugStringA(("START monitoring Windows Job ID: " + std::to_string(winJobId) + "\n").c_str());

    // Struktur untuk menyimpan info job
    DWORD bytesNeeded = 0;
    DWORD returned = 0;

    // Status flag untuk menentukan hasil akhir
    DWORD maxPagesPrintedSeen = 0;
    bool wasDeletedFlagSeen = false;
    bool wasErrorFlagSeen = false;
    bool wasOffline = false;

    int maxRetries = 600; // Timeout monitoring (misal 10 menit)
    int currentRetry = 0;

    while (currentRetry < maxRetries) {
        // 1. Coba ambil info Job spesifik dari Windows
        GetJob(hPrinter, winJobId, 2, NULL, 0, &bytesNeeded);

        if (bytesNeeded == 0) {
            break;
        }

        std::vector<BYTE> buffer(bytesNeeded);
        JOB_INFO_2* pJobInfo = reinterpret_cast<JOB_INFO_2*>(buffer.data());

        if (!GetJob(hPrinter, winJobId, 2, (LPBYTE)pJobInfo, bytesNeeded, &returned)) {
            // Gagal ambil job, kemungkinan besar Job sudah selesai dan dihapus dari spooler oleh Windows
            LogStatus("GetJob failed (Job likely finished and removed from Spooler).");
            break;
        }

        if (pJobInfo->PagesPrinted > maxPagesPrintedSeen) {
            maxPagesPrintedSeen = pJobInfo->PagesPrinted;
        }

        // 2. Analisa Status
        // Windows status adalah bitmask, bisa kombinasi beberapa status
        DWORD status = pJobInfo->Status;

        if ((status & JOB_STATUS_DELETING) || (status & JOB_STATUS_DELETED)) {
            wasDeletedFlagSeen = true;
        }
        if (status & JOB_STATUS_ERROR) {
            wasErrorFlagSeen = true;
        }
        if (status & JOB_STATUS_OFFLINE) {
            wasOffline = true;
        }
        bool isBlocked = (status & JOB_STATUS_BLOCKED_DEVQ);

        // Log detail untuk Anda debugging
        std::string statusLog = "Status Code: " + std::to_string(status) +
            " | Pages: " + std::to_string(pJobInfo->PagesPrinted) + "/" + std::to_string(pJobInfo->TotalPages);

        if (status & JOB_STATUS_PRINTING) statusLog += " [Printing]";
        if (status & JOB_STATUS_SPOOLING) statusLog += " [Spooling]";
        if (status & JOB_STATUS_ERROR)    statusLog += " [Error]";
        if (status & JOB_STATUS_OFFLINE)  statusLog += " [Offline]";
        if (status & JOB_STATUS_PAPEROUT) statusLog += " [Paper Out]";
        if (wasDeletedFlagSeen) statusLog += " [DELETING]";
        if (isBlocked) statusLog += " [Blocked]";

        LogStatus(statusLog);
        if ((status & JOB_STATUS_ERROR) || (status & JOB_STATUS_PAPEROUT) || (status & JOB_STATUS_OFFLINE)) {
            LogStatus("WARNING: Printer Error/Offline detected. Waiting...");
        }

        // Kirim update progress ke Flutter (Opsional, agar user tidak bosan menunggu)
        if (g_channel) {
            flutter::EncodableMap args = {
               {flutter::EncodableValue("status"), flutter::EncodableValue(statusLog)},
               {flutter::EncodableValue("printJobId"), flutter::EncodableValue(appPrintJobId)}
            };
            // Kita pakai event type baru misal 3 utk log/progress
            // g_channel->InvokeMethod("onPrintProgress", ...); 
        }

        // 3. Cek apakah ada Error fatal
        if (status & JOB_STATUS_ERROR || status & JOB_STATUS_PAPEROUT) {
            // Jika error, jangan break dulu, tunggu user perbaiki (isi kertas), atau break jika ingin fail fast.
            // Di sini kita log saja dan lanjut monitoring.
            LogStatus("WARNING: Printer Error/Paper Out detected. Waiting...");
        }

        // 4. Delay polling (Sleep 1 detik agar tidak makan CPU)
        std::this_thread::sleep_for(std::chrono::milliseconds(1000));
        currentRetry++;
    }

    LogStatus("Loop Finished. Analyzing Final Result...");
    LogStatus("Max Pages Seen: " + std::to_string(maxPagesPrintedSeen) + " / " + std::to_string(totalPages));


    bool isSuccess = false;

    if (wasDeletedFlagSeen) {
        isSuccess = false;
        LogStatus("RESULT: Failed (Deleted flag detected).");
    }
    else if (wasErrorFlagSeen && maxPagesPrintedSeen == 0) {
        // Error muncul DAN tidak ada halaman tercetak sama sekali sebelum hilang
        // (Asumsi: Error fatal, job dibatalkan sistem)
        isSuccess = false;
        LogStatus("RESULT: Failed (Error flag detected & 0 pages).");
    }
    else if (maxPagesPrintedSeen == 0 && totalPages > 0) {
        isSuccess = false;
        LogStatus("RESULT: Failed (Job disappeared with 0 pages printed - likely Cancelled by Admin/User).");
    }
    else {
        isSuccess = true;
        LogStatus("RESULT: Success (Job finished/handed off to printer).");
    }

    // --- KIRIM STATUS ---
    PrintEventData* data = new PrintEventData();
    data->printJobId = appPrintJobId;
    data->totalPages = totalPages;
    if (isSuccess) {
        data->type = 1; // Completed
        LogStatus("SENT: Message posted to Flutter.");
    }
    else {
        data->type = 3; // 3 = FAILED (Kita tentukan sendiri angka 3 ini sebagai kode Gagal)
        data->statusMsg = "Print Failed or Cancelled";
        LogStatus("SENT: FAILED to Flutter.");
    }
    if (g_mainWindowHandle) {
        ::PostMessage(g_mainWindowHandle, WM_FLUTTER_PRINT_EVENT, (WPARAM)data, 0);
    }
    else {
        // Fallback thread message
        ::PostThreadMessage(g_mainThreadId, WM_FLUTTER_PRINT_EVENT, (WPARAM)data, 0);
    }
    ClosePrinter(hPrinter);
}

// Helper untuk konversi WString ke String (UTF-8)
std::string WStringToString(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), NULL, 0, NULL, NULL);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(), &strTo[0], size_needed, NULL, NULL);
    return strTo;
}

// Fungsi untuk mendapatkan daftar nama kertas dari driver
std::vector<std::string> GetPrinterPaperNames(const std::string& printerName) {
    std::vector<std::string> paperNames;
    std::wstring wPrinterName(printerName.begin(), printerName.end());
    LPWSTR pPrinterName = const_cast<LPWSTR>(wPrinterName.c_str());

    // Ambil Port Name (DeviceCapabilities butuh Port, meski kadang NULL bisa jalan, lebih aman pakai Port)
    // Tapi untuk simplifikasi, biasanya NULL di parameter port DeviceCapabilities sudah cukup untuk driver modern.
    // Jika gagal, kita bisa perluas kode untuk OpenPrinter -> GetPrinter -> Ambil pPortName.
    // Kita coba NULL dulu (biasanya works).

    // 1. Cek jumlah kertas yang didukung
    DWORD count = DeviceCapabilitiesW(pPrinterName, NULL, DC_PAPERNAMES, NULL, NULL);

    if (count > 0 && count != -1) {
        // Buffer untuk nama kertas (Setiap nama max 64 karakter wide char)
        wchar_t* pPaperNames = new wchar_t[count * 64];

        if (DeviceCapabilitiesW(pPrinterName, NULL, DC_PAPERNAMES, (LPWSTR)pPaperNames, NULL) != -1) {
            for (DWORD i = 0; i < count; ++i) {
                // Ambil pointer ke string ke-i
                wchar_t* pName = pPaperNames + (i * 64);
                paperNames.push_back(WStringToString(std::wstring(pName)));
            }
        }
        delete[] pPaperNames;
    }

    return paperNames;
}

bool HasContentInMargins(PopplerPage* page, double pdfW, double pdfH, double mL, double mT, double mR, double mB) {
    int w = (int)pdfW;
    int h = (int)pdfH;

    cairo_surface_t* surface = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
    cairo_t* cr = cairo_create(surface);

    cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    cairo_paint(cr);

    poppler_page_render(page, cr);

    cairo_surface_flush(surface);
    unsigned char* data = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);

    bool hasContent = false;

    int iML = (int)mL;
    int iMT = (int)mT;
    int iMR = (int)mR;
    int iMB = (int)mB;

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < iML && x < w; x++) {
            uint32_t* pixel = (uint32_t*)(data + y * stride + x * 4);
            if ((*pixel & 0x00FFFFFF) != 0x00FFFFFF) {
                hasContent = true; goto cleanup;
            }
        }
    }

    for (int y = 0; y < iMT && y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t* pixel = (uint32_t*)(data + y * stride + x * 4);
            if ((*pixel & 0x00FFFFFF) != 0x00FFFFFF) {
                hasContent = true; goto cleanup;
            }
        }
    }

    for (int y = 0; y < h; y++) {
        for (int x = (w - iMR); x < w; x++) {
            if (x < 0) continue;
            uint32_t* pixel = (uint32_t*)(data + y * stride + x * 4);
            if ((*pixel & 0x00FFFFFF) != 0x00FFFFFF) {
                hasContent = true; goto cleanup;
            }
        }
    }

    for (int y = (h - iMB); y < h; y++) {
        if (y < 0) continue;
        for (int x = 0; x < w; x++) {
            uint32_t* pixel = (uint32_t*)(data + y * stride + x * 4);
            if ((*pixel & 0x00FFFFFF) != 0x00FFFFFF) {
                hasContent = true; goto cleanup;
            }
        }
    }

cleanup:
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return hasContent;
}

void RenderPageBorderless(HDC hdc, PopplerPage* page) {
    double width_points = 0.0, height_points = 0.0;
    poppler_page_get_size(page, &width_points, &height_points);

    // Ambil info kertas dari printer
    int offsetX = GetDeviceCaps(hdc, PHYSICALOFFSETX);
    int offsetY = GetDeviceCaps(hdc, PHYSICALOFFSETY);
    int physicalW = GetDeviceCaps(hdc, PHYSICALWIDTH);
    int physicalH = GetDeviceCaps(hdc, PHYSICALHEIGHT);
    int resX = GetDeviceCaps(hdc, HORZRES);
    int resY = GetDeviceCaps(hdc, VERTRES);

    int physRightMargin = physicalW - resX - offsetX;
    int physBottomMargin = physicalH - resY - offsetY;

    int dpiX = GetDeviceCaps(hdc, LOGPIXELSX);
    int dpiY = GetDeviceCaps(hdc, LOGPIXELSY);

    double mLeftPts = (double)offsetX * 72.0 / dpiX;
    double mTopPts = (double)offsetY * 72.0 / dpiY;
    double mRightPts = (double)physRightMargin * 72.0 / dpiX;
    double mBottomPts = (double)physBottomMargin * 72.0 / dpiY;
    bool contentInDangerZone = false;

    if (offsetX > 0 || offsetY > 0 || physRightMargin > 0 || physBottomMargin > 0) {
        contentInDangerZone = HasContentInMargins(page, width_points, height_points, mLeftPts, mTopPts, mRightPts, mBottomPts);
    }

    double scale_x, scale_y;
    double trans_x = 0, trans_y = 0;

    if (contentInDangerZone) {

        OutputDebugStringA("[Render] Konten terdeteksi di margin. Menggunakan mode FIT TO PAGE.\n");

        double paperCenterX = (double)physicalW / 2.0;
        double paperCenterY = (double)physicalH / 2.0;

        double distCenterToLeft = paperCenterX - (double)offsetX;
        double distCenterToRight = ((double)physicalW - (double)physRightMargin) - paperCenterX;

        double safeSymmetricW = std::min(distCenterToLeft, distCenterToRight) * 2.0;

        double distCenterToTop = paperCenterY - (double)offsetY;
        double distCenterToBottom = ((double)physicalH - (double)physBottomMargin) - paperCenterY;
        double safeSymmetricH = std::min(distCenterToTop, distCenterToBottom) * 2.0;

        scale_x = safeSymmetricW / width_points;
        scale_y = safeSymmetricH / height_points;

        double scale = std::min(scale_x, scale_y);
        scale_x = scale;
        scale_y = scale;

        double finalW = width_points * scale;
        double finalH = height_points * scale;

        trans_x = (paperCenterX - (finalW / 2.0)) - (double)offsetX;
        trans_y = (paperCenterY - (finalH / 2.0)) - (double)offsetY;

        // Debug info untuk cek simetri
        std::string debugMsg = "[Render] PhysW:" + std::to_string(physicalW) +
            " OffL:" + std::to_string(offsetX) +
            " OffR:" + std::to_string(physRightMargin) +
            " -> SafeW:" + std::to_string((int)safeSymmetricW) + "\n";
        OutputDebugStringA(debugMsg.c_str());

    }
    else {

        scale_x = (double)physicalW / (width_points > 0 ? width_points : 1.0);
        scale_y = (double)physicalH / (height_points > 0 ? height_points : 1.0);
        double scale = std::min(scale_x, scale_y);
        scale_x = scale;
        scale_y = scale;

        trans_x = -offsetX;
        trans_y = -offsetY;
    }

    // Buat surface Cairo untuk rendering
    cairo_surface_t* surface = cairo_win32_printing_surface_create(hdc);
    cairo_t* cr = cairo_create(surface);

    cairo_save(cr);

    // Geser canvas agar margin hardware dikompensasi
    cairo_translate(cr, trans_x, trans_y);

    // Scale konten PDF ke ukuran fisik
    cairo_scale(cr, scale_x, scale_y);

    // Render halaman
    poppler_page_render_for_printing(page, cr);

    cairo_restore(cr);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}

short GetWindowsPaperSize(std::string sizeName) {
    std::transform(sizeName.begin(), sizeName.end(), sizeName.begin(),
                   [](unsigned char c){ return (char)std::toupper(c); });
    if (sizeName == "A4") return DMPAPER_A4;
    if (sizeName == "LETTER") return DMPAPER_LETTER;
    if (sizeName == "LEGAL") return DMPAPER_LEGAL;
    if (sizeName == "A3") return DMPAPER_A3;
    if (sizeName == "A5") return DMPAPER_A5;
    if (sizeName == "F4") return DMPAPER_FOLIO;
    return DMPAPER_A4; // Default
}

// --- [UPDATED FUNCTION] Cek Status Online/Offline Printer ---
bool IsPrinterOnline(const std::string& printerName) {
    std::wstring wPrinterName(printerName.begin(), printerName.end());
    HANDLE hPrinter = nullptr;

    PRINTER_DEFAULTSW pd;
    pd.pDatatype = NULL;
    pd.pDevMode = NULL;
    pd.DesiredAccess = PRINTER_ACCESS_USE;

    if (!OpenPrinterW(const_cast<LPWSTR>(wPrinterName.c_str()), &hPrinter, &pd)) {
        //std::cout << "🔍 [Native Printer Cek] Gagal OpenPrinter. Anggap OFFLINE." << std::endl;
        return false;
    }

    DWORD bytesNeeded = 0;
    GetPrinterW(hPrinter, 2, nullptr, 0, &bytesNeeded);

    if (bytesNeeded == 0) {
        ClosePrinter(hPrinter);
        return false;
    }

    std::vector<BYTE> buffer(bytesNeeded);
    PRINTER_INFO_2W* pPrinterInfo = reinterpret_cast<PRINTER_INFO_2W*>(buffer.data());
    DWORD bytesRead = 0;

    if (!GetPrinterW(hPrinter, 2, buffer.data(), bytesNeeded, &bytesRead)) {
        ClosePrinter(hPrinter);
        return false;
    }

    ClosePrinter(hPrinter);

    // Ambil Status dan Attributes
    DWORD status = pPrinterInfo->Status;
    DWORD attributes = pPrinterInfo->Attributes;

//    std::cout << "🔍 [Native Printer Cek] Printer: " << printerName
//              << " | Status: " << status
//              << " | Attributes: " << attributes << std::endl;

    // 1. Cek dari Status
    if ((status & PRINTER_STATUS_OFFLINE) ||
        (status & PRINTER_STATUS_ERROR) ||
        (status & PRINTER_STATUS_NOT_AVAILABLE) ||
        (status & PRINTER_STATUS_PAUSED)) {
        //std::cout << "🔍 [Native Printer Cek] Hasil: Terdeteksi OFFLINE/ERROR dari Status" << std::endl;
        return false;
    }

    // 2. Cek dari Attributes (Sangat penting untuk mendeteksi printer putus koneksi)
    // PRINTER_ATTRIBUTE_WORK_OFFLINE bernilai 0x00000400 (1024)
    if (attributes & PRINTER_ATTRIBUTE_WORK_OFFLINE) {
//        std::cout << "🔍 [Native Printer Cek] Hasil: Terdeteksi OFFLINE dari Attributes (Work Offline)" << std::endl;
        return false;
    }

//    std::cout << "🔍 [Native Printer Cek] Hasil: Printer ONLINE / READY" << std::endl;
    return true;
}

bool PrintPDFFile(const std::string& filePath, const std::string& printerName, bool color, bool doubleSided, int copies, const std::string& pageOrientation, int printJobId, const std::string& pageSize, std::unique_ptr<flutter::MethodResult<>> result) {
    HANDLE hPrinter = nullptr;
    std::wstring wprinter;
    wprinter.assign(printerName.begin(), printerName.end());

    if (!OpenPrinterW(const_cast<LPWSTR>(wprinter.c_str()), &hPrinter, nullptr)) {
        result->Error("PRINTER_NOT_FOUND", "Printer not found or could not be opened.");
        OutputDebugStringA("Gagal membuka printer.\n");
        return false;
    }

    // Mendapatkan ukuran DEVMODE default
    DWORD devModeSize = DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), nullptr, nullptr, 0);
    if (devModeSize <= 0) {
        ClosePrinter(hPrinter);
        result->Error("GET_DEVMODE_SIZE_FAILED", "Failed to get DEVMODE size.");
        return false;
    }

    // Mengalokasikan memori untuk DEVMODE
    PDEVMODE pDevMode = (PDEVMODE)GlobalAlloc(GPTR, devModeSize);
    if (!pDevMode) {
        ClosePrinter(hPrinter);
        result->Error("ALLOC_DEVMODE_FAILED", "Failed to allocate memory for DEVMODE.");
        return false;
    }

    // Mendapatkan DEVMODE default
    if (DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), pDevMode, nullptr, DM_OUT_BUFFER) != IDOK) {
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
        result->Error("GET_DEVMODE_FAILED", "Failed to get default DEVMODE.");
        return false;
    }

    // --- prepare Poppler (glib) ---
    GError* gerror = nullptr;
    gchar* uri = g_filename_to_uri(filePath.c_str(), nullptr, &gerror);
    if (!uri) {
        if (gerror) {
            result->Error("FILE_URI_ERROR", gerror->message);
            g_clear_error(&gerror);
        }
        else {
            result->Error("FILE_URI_ERROR", "Failed to create file URI.");
        }
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
        return false;
    }

    PopplerDocument* doc = poppler_document_new_from_file(uri, nullptr, &gerror);
    g_free(uri);
    if (!doc) {
        if (gerror) {
            result->Error("POPPLER_LOAD_ERROR", gerror->message);
            g_clear_error(&gerror);
        }
        else {
            result->Error("POPPLER_LOAD_ERROR", "Failed to load PDF document.");
        }
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
        return false;
    }

    std::string finalOrientation = pageOrientation;
    if (pageOrientation == "auto") {
        int num_pages = poppler_document_get_n_pages(doc);
        if (num_pages > 0) {
            PopplerPage* first_page = poppler_document_get_page(doc, 0);
            double width_points = 0.0, height_points = 0.0;
            poppler_page_get_size(first_page, &width_points, &height_points);
            g_object_unref(first_page);

            if (width_points > height_points) {
                finalOrientation = "landscape";
            }
            else {
                finalOrientation = "portrait";
            }
        }
        else {
            // Jika tidak ada halaman, gunakan default portrait
            finalOrientation = "portrait";
        }
    }

    // Mengatur metadata cetak
    pDevMode->dmFields |= DM_COPIES | DM_DUPLEX | DM_COLOR | DM_ORIENTATION | DM_PRINTQUALITY | DM_YRESOLUTION | DM_PAPERSIZE;
    pDevMode->dmPaperSize = GetWindowsPaperSize(pageSize);

    // Set kualitas cetak
    pDevMode->dmPrintQuality = DMRES_HIGH;
    pDevMode->dmYResolution = pDevMode->dmPrintQuality;

    // Set jumlah salinan
    pDevMode->dmCopies = static_cast<short>(copies);

    // Set cetak bolak-balik (duplex)
    if (doubleSided) {
        if (finalOrientation == "portrait") {
            pDevMode->dmDuplex = DMDUP_VERTICAL;
        }
        else {
            pDevMode->dmDuplex = DMDUP_HORIZONTAL;
        }
    }
    else {
        pDevMode->dmDuplex = DMDUP_SIMPLEX;
    }

    // Set orientasi
    if (finalOrientation == "portrait") {
        pDevMode->dmOrientation = DMORIENT_PORTRAIT;
    }
    else {
        pDevMode->dmOrientation = DMORIENT_LANDSCAPE;
    }

    // Set warna/hitam-putih
    if (color) {
        pDevMode->dmColor = DMCOLOR_COLOR;
    }
    else {
        pDevMode->dmColor = DMCOLOR_MONOCHROME;
    }

    // Pastikan perubahan pada DEVMODE berhasil diterapkan
    if (DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), pDevMode, pDevMode, DM_IN_BUFFER | DM_OUT_BUFFER) != IDOK) {
        OutputDebugStringA("Gagal mengatur kualitas cetak tinggi. Melanjutkan dengan pengaturan default.\n");
    }

    HDC hdc = CreateDCW(nullptr, wprinter.c_str(), nullptr, pDevMode);
    GlobalFree(pDevMode);

    if (!hdc) {
        g_object_unref(doc);
        ClosePrinter(hPrinter);
        result->Error("PRINTER_NOT_FOUND", "Printer not found or Device Context could not be created.");
        OutputDebugStringA("Gagal mendapatkan Device Context untuk printer.\n");
        return false;
    }

    DOCINFO docInfo;
    ZeroMemory(&docInfo, sizeof(docInfo));
    docInfo.cbSize = sizeof(docInfo);
    docInfo.lpszDocName = L"Hlaprint Print Job";

    DWORD jobId = StartDoc(hdc, &docInfo);
    if (jobId <= 0) {
        g_object_unref(doc);
        DeleteDC(hdc);
        ClosePrinter(hPrinter);
        result->Error("START_DOC_FAILED", "Failed to start print document.");
        return false;
    }

    // Kirim respons awal ke Flutter bahwa pekerjaan sudah dikirim ke printer
    result->Success(flutter::EncodableValue("Sent To Printer"));

    

    int num_pages = poppler_document_get_n_pages(doc);

    // Logika untuk menentukan rentang halaman yang akan dicetak
    int start_index = 0;
    int end_index = num_pages;

    OutputDebugStringA(("Mencetak full dokumen: " + std::to_string(num_pages) + " halaman.\n").c_str());

    // Pastikan rentang halaman tidak melebihi jumlah halaman total
    end_index = std::min(num_pages, end_index);

    int totalPagesToPrint = end_index - start_index;

    for (int i = start_index; i < end_index; ++i) {
        if (i < 0 || i >= num_pages) {
            continue;
        }

        PopplerPage* page = poppler_document_get_page(doc, i);
        if (!page) continue;

        if (StartPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            ClosePrinter(hPrinter);
            result->Error("START_PAGE_FAILED", "Failed to start print page.");
            return false;
        }

        RenderPageBorderless(hdc, page);

        if (EndPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            ClosePrinter(hPrinter);
            result->Error("END_PAGE_FAILED", "Failed to end print page.");
            return false;
        }

        g_object_unref(page);
    }

    EndDoc(hdc);
    DeleteDC(hdc);
    g_object_unref(doc);

    if (printJobId > 0) {
        std::thread(MonitorPrintJob, hPrinter, jobId, printJobId, totalPagesToPrint).detach();
    }

    return true;
}


void RegisterMethodChannel(flutter::FlutterViewController* flutter_controller) {
    OutputDebugStringA("Mendaftarkan Method Channel...\n");
    g_channel = std::make_unique<flutter::MethodChannel<>>(
        flutter_controller->engine()->messenger(), "com.hlaprint.app/printing",
        &flutter::StandardMethodCodec::GetInstance());

    g_channel->SetMethodCallHandler(
        [](const flutter::MethodCall<>& call,
            std::unique_ptr<flutter::MethodResult<>> result) {
                if (call.method_name().compare("printPDF") == 0) {
                    OutputDebugStringA("Panggilan 'printPDF' diterima.\n");
                    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                    if (args) {
                        const auto& file_path_val = args->find(flutter::EncodableValue("filePath"));
                        const auto& printer_name_val = args->find(flutter::EncodableValue("printerName"));
                        const auto& color_val = args->find(flutter::EncodableValue("color"));
                        const auto& double_sided_val = args->find(flutter::EncodableValue("doubleSided"));
                        const auto& copies_val = args->find(flutter::EncodableValue("copies"));
                        const auto& orientation_val = args->find(flutter::EncodableValue("pageOrientation"));
                        const auto& print_job_id_val = args->find(flutter::EncodableValue("printJobId"));
                        std::string pageSize = "A4";
                        auto itSize = args->find(flutter::EncodableValue("pageSize"));
                        if (itSize != args->end()) {
                            if (std::holds_alternative<std::string>(itSize->second)) {
                                pageSize = std::get<std::string>(itSize->second);
                            }
                        }

                        if (file_path_val != args->end() && printer_name_val != args->end() &&
                            color_val != args->end() && double_sided_val != args->end() &&
                            copies_val != args->end() && orientation_val != args->end() &&
                            print_job_id_val != args->end()) {

                            std::string filePath = std::get<std::string>(file_path_val->second);
                            std::string printerName = std::get<std::string>(printer_name_val->second);
                            bool color = std::get<bool>(color_val->second);
                            bool doubleSided = std::get<bool>(double_sided_val->second);
                            int copies = std::get<int>(copies_val->second);
                            std::string pageOrientation = std::get<std::string>(orientation_val->second);
                            int printJobId = std::get<int>(print_job_id_val->second);

                            PrintPDFFile(filePath, printerName, color, doubleSided, copies, pageOrientation, printJobId, pageSize, std::move(result));
                            return;
                        }
                    }
                    result->Error("INVALID_ARGUMENTS", "File path or printer name not provided.");
                }
                else if (call.method_name() == "getPrinterStatus") {
                    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                    std::string printerName;

                    if (args) {
                        auto it = args->find(flutter::EncodableValue("printerName"));
                        if (it != args->end()) {
                            printerName = std::get<std::string>(it->second);
                        }
                    }

                    if (printerName.empty()) {
                        result->Error("INVALID_ARGUMENTS", "Printer name required");
                        return;
                    }

                    // Panggil fungsi helper baru
                    bool isOnline = IsPrinterOnline(printerName);

                    // Kembalikan boolean ke Flutter (true = Online, false = Offline)
                    result->Success(flutter::EncodableValue(isOnline));
                }
                else if (call.method_name() == "monitorLastJob") {
                    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                    std::string printerName;
                    int printJobId = 0;

                    if (args) {
                        auto it = args->find(flutter::EncodableValue("printerName"));
                        if (it != args->end()) printerName = std::get<std::string>(it->second);

                        it = args->find(flutter::EncodableValue("printJobId"));
                        if (it != args->end()) printJobId = std::get<int>(it->second);
                        if (printJobId <= 0) {
                            std::cout << "Ignoring monitor request for system job ID: " << printJobId << std::endl;
                            result->Success(flutter::EncodableValue("ignored"));
                            return;
                        }
                    }

                    // Jalankan monitoring di thread terpisah agar UI tidak freeze
                    std::thread([printerName, printJobId]() {
                        HANDLE hPrinter = nullptr;
                        if (OpenPrinterA(const_cast<LPSTR>(printerName.c_str()), &hPrinter, nullptr)) {

                            // 1. Cari Job ID terbaru (Highest ID) di Printer tersebut
                            DWORD bytesNeeded = 0, count = 0;
                            EnumJobs(hPrinter, 0, 100, 2, nullptr, 0, &bytesNeeded, &count);

                            std::vector<BYTE> buffer(bytesNeeded);
                            if (EnumJobs(hPrinter, 0, 100, 2, buffer.data(), bytesNeeded, &bytesNeeded, &count)) {
                                JOB_INFO_2* jobs = reinterpret_cast<JOB_INFO_2*>(buffer.data());
                                DWORD maxJobId = 0;

                                // Loop untuk mencari ID terbesar (Terbaru)
                                for (DWORD i = 0; i < count; ++i) {
                                    if (jobs[i].JobId > maxJobId) {
                                        maxJobId = jobs[i].JobId;
                                    }
                                }

                                if (maxJobId > 0) {
                                    // 2. Gunakan fungsi Monitor yang sudah ada untuk memantau Job Sumatra ini
                                    MonitorPrintJob(hPrinter, maxJobId, printJobId, 0);
                                } else {
                                    // Tidak ada job ditemukan (mungkin print sangat cepat selesai atau gagal masuk spooler)
                                    // Kita bisa kirim completed langsung atau log error
                                    PrintEventData* data = new PrintEventData{ 1, printJobId, 0, "No Job Found" };
                                    PostThreadMessage(g_mainThreadId, WM_FLUTTER_PRINT_EVENT, (WPARAM)data, 0);
                                    ClosePrinter(hPrinter);
                                }
                            }
                        }
                    }).detach();

                    result->Success(flutter::EncodableValue("Monitoring Started"));
                }
                else if (call.method_name() == "getPrinterPaperSizes") {
                    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                    std::string printerName;

                    if (args) {
                        // Cek 'ip' atau 'printerName'
                        auto it = args->find(flutter::EncodableValue("ip"));
                        if (it == args->end()) it = args->find(flutter::EncodableValue("printerName"));

                        if (it != args->end()) {
                            printerName = std::get<std::string>(it->second);
                        }
                    }

                    if (printerName.empty()) {
                        result->Error("INVALID_ARGUMENTS", "Printer name required");
                        return;
                    }

                    // Panggil fungsi helper
                    std::vector<std::string> papers = GetPrinterPaperNames(printerName);

                    // Convert vector ke Flutter List
                    flutter::EncodableList list;
                    for (const auto& name : papers) {
                        list.push_back(flutter::EncodableValue(name));
                    }

                    result->Success(list);
                }
                else {
                    OutputDebugStringA("Metode tidak diimplementasikan.\\n");
                    result->NotImplemented();
                }
        });
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
    _In_ wchar_t* command_line, _In_ int show_command) {
    g_mainThreadId = ::GetCurrentThreadId();

    if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
        CreateAndAttachConsole();
    }

    ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    flutter::DartProject project(L"data");

    std::vector<std::string> command_line_arguments =
        GetCommandLineArguments();

    project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (!window.Create(L"Hlaprint", origin, size)) {
        return EXIT_FAILURE;
    }
    g_mainWindowHandle = window.GetHandle();
    window.SetQuitOnClose(true);

    if (window.GetFlutterViewController()) {
        RegisterMethodChannel(window.GetFlutterViewController());
    }

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
        if (msg.message == WM_FLUTTER_PRINT_EVENT) {
            PrintEventData* data = (PrintEventData*)msg.wParam;

            if (data && g_channel) {
                if (data->type == 1) { // Job Completed
                    flutter::EncodableMap args = {
                        {flutter::EncodableValue("printJobId"), flutter::EncodableValue(data->printJobId)},
                        {flutter::EncodableValue("totalPages"), flutter::EncodableValue(data->totalPages)}
                    };
                    g_channel->InvokeMethod("onPrintJobCompleted", std::make_unique<flutter::EncodableValue>(args));
                }
                else if (data->type == 2) { // Status Update
                    g_channel->InvokeMethod("onPrinterStatus", std::make_unique<flutter::EncodableValue>(data->statusMsg));
                }
                else if (data->type == 3) { // Job Failed / Cancelled
                    flutter::EncodableMap args = {
                            {flutter::EncodableValue("printJobId"), flutter::EncodableValue(data->printJobId)},
                            {flutter::EncodableValue("error"), flutter::EncodableValue(data->statusMsg)}
                    };
                    g_channel->InvokeMethod("onPrintJobFailed", std::make_unique<flutter::EncodableValue>(args));
                }

                delete data;
            }
            continue;
        }
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
    }

    ::CoUninitialize();
    return EXIT_SUCCESS;
}