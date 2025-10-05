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
#include <algorithm>
#include <glib.h>
#include <poppler/glib/poppler.h>
#include <cairo/cairo-win32.h>
#include "flutter_window.h"
#include "utils.h"


std::unique_ptr<flutter::MethodChannel<>> g_channel;

void MonitorPrintJob(HANDLE hPrinter, DWORD jobId, int printJobId, int totalPages) {
    OutputDebugStringA(("[MonitorJob] Polling job via EnumJobs (JOB_INFO_2), JobId=" + std::to_string(jobId) + "\n").c_str());

    bool alreadyReported = false;

    while (true) {
        DWORD needed = 0, returned = 0;
        EnumJobs(hPrinter, 0, 255, 2, nullptr, 0, &needed, &returned);
        if (needed == 0) {
            Sleep(1000);
            continue;
        }


        JOB_INFO_2* pJobs = (JOB_INFO_2*)malloc(needed);
        if (!EnumJobs(hPrinter, 0, 255, 2, (LPBYTE)pJobs, needed, &needed, &returned)) {
            free(pJobs);
            Sleep(1000);
            continue;
        }


        bool found = false;
        for (DWORD i = 0; i < returned; i++) {
            if (pJobs[i].JobId == jobId) {
                found = true;
                std::string msg = "[MonitorJob] Job ditemukan di spooler, Status=" + std::to_string(pJobs[i].Status);
                OutputDebugStringA((msg + "\n").c_str());


                if (!alreadyReported && ((pJobs[i].Status & JOB_STATUS_COMPLETE) || pJobs[i].Status == 8208)) {
                    std::string dbg = "[MonitorJob] COMPLETE flag terdeteksi (Status=" + std::to_string(pJobs[i].Status) + "), kirim event ke Dart segera.\n";
                    OutputDebugStringA(dbg.c_str());


                    if (g_channel) {
                        flutter::EncodableMap args = {
                            {flutter::EncodableValue("printJobId"), flutter::EncodableValue(printJobId)},
                            {flutter::EncodableValue("totalPages"), flutter::EncodableValue(totalPages)}
                        };
                        g_channel->InvokeMethod(
                            "onPrintJobCompleted",
                            std::make_unique<flutter::EncodableValue>(args)
                        );
                    }
                    alreadyReported = true;
                    free(pJobs);
                    ClosePrinter(hPrinter);
                    return;
                }
                break;
            }
        }
        free(pJobs);


        if (!found) {
            OutputDebugStringA("[MonitorJob] Job tidak ditemukan di spooler, anggap sudah selesai/cancel.\n");
            if (!alreadyReported) {
                if (g_channel) {
                    g_channel->InvokeMethod(
                        "onPrintJobCompleted",
                        std::make_unique<flutter::EncodableValue>(printJobId)
                    );
                }
            }
            ClosePrinter(hPrinter);
            return;
        }


        Sleep(1000);
    }
}

void MonitorPrinterStatus(const std::wstring& printerName) {
    HANDLE hPrinter = nullptr;
    if (!OpenPrinterW(const_cast<LPWSTR>(printerName.c_str()), &hPrinter, nullptr)) {
        OutputDebugStringA("Tidak bisa membuka printer untuk monitoring.\n");
        return;
    }

    // Kirim status awal
    {
        DWORD needed = 0;
        GetPrinterW(hPrinter, 6, nullptr, 0, &needed);
        if (needed > 0) {
            PRINTER_INFO_6* pInfo6 = (PRINTER_INFO_6*)malloc(needed);
            if (GetPrinterW(hPrinter, 6, (LPBYTE)pInfo6, needed, &needed)) {
                std::string status = (pInfo6->dwStatus & PRINTER_STATUS_OFFLINE) ? "Offline" : "Online";
                if (g_channel) {
                    OutputDebugStringA("Kirim status awal.\n");
                    g_channel->InvokeMethod("onPrinterStatus",
                        std::make_unique<flutter::EncodableValue>(status));
                }
            }
            free(pInfo6);
        }
    }

    // Buat notification handle
    HANDLE hChange = FindFirstPrinterChangeNotification(
        hPrinter,
        PRINTER_CHANGE_SET_PRINTER | PRINTER_CHANGE_FAILED_CONNECTION_PRINTER,
        0,
        nullptr
    );

    if (hChange == INVALID_HANDLE_VALUE) {
        OutputDebugStringA("Gagal membuat printer change notification.\n");
        ClosePrinter(hPrinter);
        return;
    }

    while (true) {
        DWORD waitStatus = WaitForSingleObject(hChange, INFINITE);
        if (waitStatus == WAIT_OBJECT_0) {
            // Ada perubahan pada printer
            DWORD needed = 0;
            GetPrinterW(hPrinter, 6, nullptr, 0, &needed);
            if (needed > 0) {
                PRINTER_INFO_6* pInfo6 = (PRINTER_INFO_6*)malloc(needed);
                if (GetPrinterW(hPrinter, 6, (LPBYTE)pInfo6, needed, &needed)) {
                    std::string status = (pInfo6->dwStatus & PRINTER_STATUS_OFFLINE) ? "Offline" : "Online";
                    if (g_channel) {
                        OutputDebugStringA("Kirim status looping.\n");
                        g_channel->InvokeMethod("onPrinterStatus",
                            std::make_unique<flutter::EncodableValue>(status));
                    }
                }
                free(pInfo6);
            }

            // Reset notification
            if (!FindNextPrinterChangeNotification(hChange, nullptr, nullptr, nullptr)) {
                OutputDebugStringA("Gagal reset printer change notification.\n");
                break;
            }
        }
        else {
            OutputDebugStringA("WaitForSingleObject gagal atau dibatalkan.\n");
            break;
        }
    }

    FindClosePrinterChangeNotification(hChange);
    ClosePrinter(hPrinter);
}


void RenderPageBorderless(HDC hdc, PopplerPage* page) {
    double width_points = 0.0, height_points = 0.0;
    poppler_page_get_size(page, &width_points, &height_points);

    // Ambil info kertas dari printer
    int offsetX = GetDeviceCaps(hdc, PHYSICALOFFSETX);
    int offsetY = GetDeviceCaps(hdc, PHYSICALOFFSETY);
    int physicalW = GetDeviceCaps(hdc, PHYSICALWIDTH);
    int physicalH = GetDeviceCaps(hdc, PHYSICALHEIGHT);

    // Hitung skala supaya pas dengan ukuran fisik kertas penuh
    double scale_x = (double)physicalW / (width_points > 0 ? width_points : 1.0);
    double scale_y = (double)physicalH / (height_points > 0 ? height_points : 1.0);
    double scale = std::min(scale_x, scale_y);

    // Buat surface Cairo untuk rendering
    cairo_surface_t* surface = cairo_win32_printing_surface_create(hdc);
    cairo_t* cr = cairo_create(surface);

    cairo_save(cr);

    // Geser canvas agar margin hardware dikompensasi
    cairo_translate(cr, -offsetX, -offsetY);

    // Scale konten PDF ke ukuran fisik
    cairo_scale(cr, scale, scale);

    // Render halaman
    poppler_page_render_for_printing(page, cr);

    cairo_restore(cr);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
}

bool PrintPDFFile(const std::string& filePath, const std::string& printerName, bool color, bool doubleSided, int pagesStart, int pageEnd, int copies, const std::string& pageOrientation, int printJobId, std::unique_ptr<flutter::MethodResult<>> result) {
    HANDLE hPrinter = nullptr;
    std::wstring wprinter;
    wprinter.assign(printerName.begin(), printerName.end());

    if (!OpenPrinterW(const_cast<LPWSTR>(wprinter.c_str()), &hPrinter, nullptr)) {
        result->Error("PRINTER_NOT_FOUND", "Printer tidak ditemukan atau tidak bisa dibuka.");
        OutputDebugStringA("Gagal membuka printer.\n");
        return false;
    }

    // Mendapatkan ukuran DEVMODE default
    DWORD devModeSize = DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), nullptr, nullptr, 0);
    if (devModeSize <= 0) {
        ClosePrinter(hPrinter);
        result->Error("GET_DEVMODE_SIZE_FAILED", "Gagal mendapatkan ukuran DEVMODE.");
        return false;
    }

    // Mengalokasikan memori untuk DEVMODE
    PDEVMODE pDevMode = (PDEVMODE)GlobalAlloc(GPTR, devModeSize);
    if (!pDevMode) {
        ClosePrinter(hPrinter);
        result->Error("ALLOC_DEVMODE_FAILED", "Gagal mengalokasikan memori untuk DEVMODE.");
        return false;
    }

    // Mendapatkan DEVMODE default
    if (DocumentPropertiesW(nullptr, hPrinter, const_cast<LPWSTR>(wprinter.c_str()), pDevMode, nullptr, DM_OUT_BUFFER) != IDOK) {
        GlobalFree(pDevMode);
        ClosePrinter(hPrinter);
        result->Error("GET_DEVMODE_FAILED", "Gagal mendapatkan DEVMODE default.");
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
            result->Error("FILE_URI_ERROR", "Gagal membentuk URI file.");
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
            result->Error("POPPLER_LOAD_ERROR", "Gagal memuat dokumen PDF.");
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
    pDevMode->dmPaperSize = DMPAPER_A4;

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
        result->Error("PRINTER_NOT_FOUND", "Printer tidak ditemukan atau tidak bisa dibuka.");
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
        result->Error("START_DOC_FAILED", "Gagal memulai dokumen cetak.");
        return false;
    }

    // Kirim respons awal ke Flutter bahwa pekerjaan sudah dikirim ke printer
    result->Success(flutter::EncodableValue("Sent To Printer"));

    

    int num_pages = poppler_document_get_n_pages(doc);

    // Logika untuk menentukan rentang halaman yang akan dicetak
    int start_index;
    int end_index;

    // Periksa validitas masukan pengguna
    if (pagesStart <= 0 || pageEnd <= 0 || pagesStart > pageEnd || pagesStart > num_pages) {
        // Jika input tidak valid, cetak semua halaman
        start_index = 0;
        end_index = num_pages;
        OutputDebugStringA(("Masukan halaman tidak valid. Mencetak semua " + std::to_string(num_pages) + " halaman.\n").c_str());
    }
    else {
        // Jika input valid, tentukan rentang yang diminta
        start_index = pagesStart - 1;
        end_index = pageEnd;
        OutputDebugStringA(("Mencetak halaman dari " + std::to_string(pagesStart) + " sampai " + std::to_string(pageEnd) + ".\n").c_str());
    }

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
            result->Error("START_PAGE_FAILED", "Gagal memulai halaman cetak.");
            return false;
        }

        RenderPageBorderless(hdc, page);

        if (EndPage(hdc) <= 0) {
            g_object_unref(page);
            EndDoc(hdc);
            g_object_unref(doc);
            DeleteDC(hdc);
            ClosePrinter(hPrinter);
            result->Error("END_PAGE_FAILED", "Gagal mengakhiri halaman cetak.");
            return false;
        }

        g_object_unref(page);
    }

    EndDoc(hdc);
    DeleteDC(hdc);
    g_object_unref(doc);

    std::thread(MonitorPrintJob, hPrinter, jobId, printJobId, totalPagesToPrint).detach();

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
                        const auto& pages_start_val = args->find(flutter::EncodableValue("pagesStart"));
                        const auto& page_end_val = args->find(flutter::EncodableValue("pageEnd"));
                        const auto& copies_val = args->find(flutter::EncodableValue("copies"));
                        const auto& orientation_val = args->find(flutter::EncodableValue("pageOrientation"));
                        const auto& print_job_id_val = args->find(flutter::EncodableValue("printJobId"));

                        if (file_path_val != args->end() && printer_name_val != args->end() &&
                            color_val != args->end() && double_sided_val != args->end() &&
                            pages_start_val != args->end() && page_end_val != args->end() &&
                            copies_val != args->end() && orientation_val != args->end() &&
                            print_job_id_val != args->end()) {

                            std::string filePath = std::get<std::string>(file_path_val->second);
                            std::string printerName = std::get<std::string>(printer_name_val->second);
                            bool color = std::get<bool>(color_val->second);
                            bool doubleSided = std::get<bool>(double_sided_val->second);
                            int pagesStart = std::get<int>(pages_start_val->second);
                            int pageEnd = std::get<int>(page_end_val->second);
                            int copies = std::get<int>(copies_val->second);
                            std::string pageOrientation = std::get<std::string>(orientation_val->second);
                            int printJobId = std::get<int>(print_job_id_val->second);

                            PrintPDFFile(filePath, printerName, color, doubleSided, pagesStart, pageEnd, copies, pageOrientation, printJobId, std::move(result));
                            return;
                        }
                    }
                    OutputDebugStringA("Argumen tidak valid.\n");
                    result->Error("INVALID_ARGUMENTS", "File path or printer name not provided.");
                }
                else if (call.method_name().compare("startMonitorPrinter") == 0) {
                    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
                    if (args) {
                        auto it = args->find(flutter::EncodableValue("printerName"));
                        if (it != args->end()) {
                            std::string printerName = std::get<std::string>(it->second);
                            std::wstring wprinter(printerName.begin(), printerName.end());
                            std::thread(MonitorPrinterStatus, wprinter).detach();
                            result->Success();
                            return;
                        }
                    }
                    result->Error("INVALID_ARGUMENTS", "Printer name not provided.");
                }
                else {
                    OutputDebugStringA("Metode tidak diimplementasikan.\\n");
                    result->NotImplemented();
                }
        });
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
    _In_ wchar_t* command_line, _In_ int show_command) {
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
    if (!window.Create(L"hlaprint", origin, size)) {
        return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    if (window.GetFlutterViewController()) {
        RegisterMethodChannel(window.GetFlutterViewController());
    }

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
    }

    ::CoUninitialize();
    return EXIT_SUCCESS;
}